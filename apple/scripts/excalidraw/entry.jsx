// The app's Excalidraw page: the draw overlay on a terminal pane and the canvas pane.
// Bridge contract: docs/DAEMON.md §7.11. Swift → JS calls window.canvas.<fn>(json);
// JS → Swift posts to window.webkit.messageHandlers.canvas.
//
// Built by apple/scripts/build-excalidraw.sh into apple/App/Resources/Excalidraw/.

import React, { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import {
  CaptureUpdateAction,
  Excalidraw,
  MainMenu,
  convertToExcalidrawElements,
  exportToBlob,
  exportToSvg,
  getCommonBounds,
  reconcileElements,
  restoreElements,
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";

const VERSION = "0.18.1";

function post(msg) {
  try {
    window.webkit.messageHandlers.canvas.postMessage(msg);
  } catch {
    // Opened in a plain browser (development): log instead.
    console.log("canvas →", msg.type);
  }
}

const state = {
  api: null,
  config: null,
  // Element id → highest version this page has seen (its own edits or the host's). Only
  // elements whose version grew since are posted as changes.
  known: new Map(),
  pending: new Map(),
  flushTimer: null,
  // File ids already known to the host (loaded from it or posted to it).
  files: new Set(),
  viewport: null,
  lastPointer: 0,
  // The editor has applied the loaded scene (initialData is applied asynchronously; elements
  // added before that were replaced by the scene and lost: strokes vanished on a real iPad).
  loaded: false,
  // Ink and other work that arrived before the scene loaded.
  waiting: [],
  // The tool the host chose (Excalidraw type) and the last one reported back to it.
  tool: null,
  reportedTool: null,
  // The scene as loaded, for Cancel on a reopened drawing (revert).
  initial: [],
};

let setConfig = () => {};

// MARK: Swift → JS

function load(config) {
  state.api = null;
  state.loaded = false;
  state.initial = (config.elements || []).map((e) => ({ ...e }));
  state.known = new Map();
  state.pending = new Map();
  state.files = new Set((config.files || []).map((f) => f.id));
  for (const el of config.elements || []) state.known.set(el.id, el.version);
  state.viewport = config.viewport || null;
  document.body.dataset.mode = config.mode || "canvas";
  document.body.dataset.theme = config.theme || "dark";
  state.config = { ...config, key: (state.config?.key || 0) + 1 };
  setConfig(state.config);
}

// Text that arrives from outside the editor (remote edits, added skeletons) can be drawn before
// its face has loaded and stay in the fallback serif (the editor's own text tool loads fonts
// first). Once the faces are in, hand the editor fresh copies of those text elements (same
// version, so nothing is re-sent) to drop their cached renders.
function redrawTextWhenFontsLoad(elements) {
  if (!elements.some((e) => e.type === "text")) return;
  const faces = ["Excalifont", "Virgil", "Nunito", "Lilita One", "Comic Shanns", "Liberation Sans", "Cascadia"];
  Promise.all(faces.map((f) => document.fonts.load(`20px "${f}"`).catch(() => null))).then(() => {
    const api = state.api;
    if (!api) return;
    api.updateScene({
      // Fresh objects re-measured with the real face (bound labels re-centred in their boxes).
      elements: restoreElements(api.getSceneElementsIncludingDeleted(), null, { refreshDimensions: true, repairBindings: false }),
      captureUpdate: CaptureUpdateAction.NEVER,
    });
  });
}

function applyRemote({ elements = [], files = [] }) {
  const api = state.api;
  if (!api) return;
  if (files.length) {
    for (const f of files) state.files.add(f.id);
    api.addFiles(files.map((f) => ({ ...f, created: Date.now() })));
  }
  if (!elements.length) return;
  const remote = restoreElements(elements, null);
  for (const el of remote) {
    if ((state.known.get(el.id) ?? -1) < el.version) state.known.set(el.id, el.version);
  }
  const merged = reconcileElements(api.getSceneElementsIncludingDeleted(), remote, api.getAppState());
  api.updateScene({ elements: merged, captureUpdate: CaptureUpdateAction.NEVER });
  redrawTextWhenFontsLoad(remote);
}

function sceneLoaded() {
  if (state.loaded || !state.api) return;
  state.loaded = true;
  // Never Excalidraw's pen mode: once a Pencil touched the page it stopped fingers from drawing
  // shapes (App `allowOnPointerDown`). Touch routing belongs to the host.
  state.api.updateScene({ appState: { penMode: false, penDetected: true }, captureUpdate: CaptureUpdateAction.NEVER });
  if (state.tool) applyTool();
  const waiting = state.waiting;
  state.waiting = [];
  for (const work of waiting) work();
  post({ type: "loaded", count: state.api.getSceneElements().length });
}

// Ink converted from PencilKit: added as the user's own edit (undoable, posted back as a
// change), then acknowledged once drawn so the host can drop its live stroke without a gap.
// Ink that arrives before the scene has loaded waits for it.
function addElements({ elements = [] }) {
  if (!elements.length) return;
  if (!state.api || !state.loaded) {
    state.waiting.push(() => addElements({ elements }));
    return;
  }
  const api = state.api;
  // A resend of an element already in the scene: confirm it again, never duplicate it.
  const have = new Set(api.getSceneElementsIncludingDeleted().map((e) => e.id));
  const fresh = elements.filter((e) => !have.has(e.id));
  if (!fresh.length) {
    post({ type: "inkApplied", ids: elements.map((e) => e.id), resent: true });
    return;
  }
  elements = fresh;
  const restored = restoreElements(elements, null);
  api.updateScene({
    elements: [...api.getSceneElementsIncludingDeleted(), ...restored],
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  });
  const ids = restored.map((e) => e.id);
  requestAnimationFrame(() => requestAnimationFrame(() => post({ type: "inkApplied", ids })));
}

function setViewport(viewport) {
  state.viewport = viewport;
  applyViewport();
}

function applyViewport() {
  const api = state.api;
  const v = state.viewport;
  if (!api || !v) return;
  api.updateScene({
    appState: { scrollX: v.originX / v.zoom, scrollY: v.originY / v.zoom, zoom: { value: v.zoom } },
    captureUpdate: CaptureUpdateAction.NEVER,
  });
}

// The host's toolbar picks the tool; it stays picked after each shape (locked), so a finger
// keeps drawing with it.
function setTool({ type }) {
  state.tool = type;
  if (state.api && state.loaded) applyTool();
}

function applyTool() {
  const api = state.api;
  const type = state.tool;
  if (!api || !type) return;
  state.reportedTool = type;
  api.setActiveTool(type === "selection" ? { type } : { type, locked: true });
}

// Cancel on a reopened drawing: every element goes back to how it was loaded (edits since are
// overwritten with higher versions, new elements deleted), posted as the user's own change.
function revert() {
  const api = state.api;
  if (!api) return post({ type: "reverted", count: 0 });
  const initial = new Map(state.initial.map((e) => [e.id, e]));
  const nonce = () => Math.floor(Math.random() * 2 ** 31);
  let count = 0;
  const next = api.getSceneElementsIncludingDeleted().map((el) => {
    const was = initial.get(el.id);
    initial.delete(el.id);
    if (!was) {
      if (el.isDeleted) return el;
      count++;
      return { ...el, isDeleted: true, version: el.version + 1, versionNonce: nonce(), updated: Date.now() };
    }
    if (was.version === el.version && !!was.isDeleted === !!el.isDeleted) return el;
    count++;
    return { ...was, isDeleted: false, version: Math.max(el.version, was.version) + 1, versionNonce: nonce(), updated: Date.now() };
  });
  for (const was of initial.values()) {
    count++;
    next.push({ ...was, version: was.version + 1, versionNonce: nonce(), updated: Date.now() });
  }
  api.updateScene({ elements: restoreElements(next, null), captureUpdate: CaptureUpdateAction.IMMEDIATELY });
  post({ type: "reverted", count });
}

function setTheme({ theme }) {
  document.body.dataset.theme = theme;
  if (state.config) {
    state.config = { ...state.config, theme };
    setConfig(state.config);
  }
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

// Excalidraw's dark theme is a CSS filter on the canvas (invert(93%) hue-rotate(180deg)); its
// PNG export applies it with the canvas 2D \`filter\`, which WebKit does not implement. Apply the
// same color matrix to the pixels so the placed image looks like the editor did.
async function darken(blob) {
  const bitmap = await createImageBitmap(blob);
  const canvas = document.createElement("canvas");
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bitmap, 0, 0);
  const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
  const p = image.data;
  const m = [-0.574, 1.43, 0.144, 0.426, 0.43, 0.144, 0.426, 1.43, -0.856];
  for (let i = 0; i < p.length; i += 4) {
    if (p[i + 3] === 0) continue;
    const r = 0.93 - 0.86 * (p[i] / 255), g = 0.93 - 0.86 * (p[i + 1] / 255), b = 0.93 - 0.86 * (p[i + 2] / 255);
    p[i] = Math.max(0, Math.min(255, (m[0] * r + m[1] * g + m[2] * b) * 255));
    p[i + 1] = Math.max(0, Math.min(255, (m[3] * r + m[4] * g + m[5] * b) * 255));
    p[i + 2] = Math.max(0, Math.min(255, (m[6] * r + m[7] * g + m[8] * b) * 255));
  }
  ctx.putImageData(image, 0, 0);
  return await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
}

// An invisible rectangle that fixes the exported area (the overlay's covered cells), so
// the PNG lines up with the grid it is placed on.
function boundsElement({ x, y, width, height }) {
  return convertToExcalidrawElements([
    {
      type: "rectangle",
      x,
      y,
      width,
      height,
      strokeColor: "transparent",
      backgroundColor: "transparent",
      opacity: 0,
      strokeWidth: 1,
    },
  ])[0];
}

async function exportImage({ requestId, format = "png", scale = 2, exportPadding = 0, bounds = null, background = false }) {
  const api = state.api;
  if (!api) return post({ type: "export", requestId, error: "not loaded" });
  try {
    const drawn = api.getSceneElements();
    const elements = bounds ? [...drawn, boundsElement(bounds)] : drawn;
    const appState = {
      ...api.getAppState(),
      exportBackground: background,
      exportWithDarkMode: (state.config?.theme || "dark") === "dark",
      exportScale: scale,
    };
    const files = api.getFiles();
    let data;
    if (format === "svg") {
      const svg = await exportToSvg({ elements, appState, files, exportPadding });
      data = btoa(unescape(encodeURIComponent(svg.outerHTML)));
    } else {
      const blob = await exportToBlob({
        elements,
        appState,
        files,
        exportPadding,
        mimeType: "image/png",
        getDimensions: (width, height) => ({ width: width * scale, height: height * scale, scale }),
      });
      data = await blobToBase64(appState.exportWithDarkMode ? await darken(blob) : blob);
    }
    post({ type: "export", requestId, data, count: drawn.length });
  } catch (error) {
    post({ type: "export", requestId, error: String(error) });
  }
}

// The drawn elements' bounds in scene px, or null for an empty scene.
function bounds() {
  const drawn = state.api ? state.api.getSceneElements() : [];
  if (!drawn.length) return null;
  const [minX, minY, maxX, maxY] = getCommonBounds(drawn);
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY, count: drawn.length };
}

// Posts pending changes now (before Done / Send).
function flushNow() {
  if (state.flushTimer) clearTimeout(state.flushTimer);
  flush();
}

// Debug and UI tests: adds a rectangle as if drawn with the rectangle tool.
function debugRect({ x, y, width, height }) {
  const api = state.api;
  if (!api) return;
  const [rect] = convertToExcalidrawElements([{ type: "rectangle", x, y, width, height, strokeColor: "#e03131", strokeWidth: 2 }]);
  api.updateScene({ elements: [...api.getSceneElementsIncludingDeleted(), rect], captureUpdate: CaptureUpdateAction.IMMEDIATELY });
}

// Debug: an arrow between two scene points.
function debugArrow({ x1, y1, x2, y2 }) {
  const api = state.api;
  if (!api) return;
  const [arrow] = convertToExcalidrawElements([
    { type: "arrow", x: x1, y: y1, width: x2 - x1, height: y2 - y1, points: [[0, 0], [x2 - x1, y2 - y1]], strokeColor: "#1971c2", strokeWidth: 2 },
  ]);
  api.updateScene({ elements: [...api.getSceneElementsIncludingDeleted(), arrow], captureUpdate: CaptureUpdateAction.IMMEDIATELY });
}

// Debug: Excalidraw element skeletons (convertToExcalidrawElements), e.g. labelled boxes.
async function debugSkeleton({ elements = [] }) {
  const api = state.api;
  if (!api) return;
  // Measure labels with the real face, not the fallback.
  await document.fonts.load('20px "Excalifont"').catch(() => null);
  const made = convertToExcalidrawElements(elements);
  api.updateScene({ elements: [...api.getSceneElementsIncludingDeleted(), ...made], captureUpdate: CaptureUpdateAction.IMMEDIATELY });
  api.scrollToContent(made, { fitToContent: true, animate: false });
  redrawTextWhenFontsLoad(made);
}

// Debug and tests: the scene as the editor holds it.
function snapshot() {
  const api = state.api;
  return JSON.stringify({ elements: api ? api.getSceneElements() : [], tool: api?.getAppState().activeTool.type });
}

window.canvas = { load, applyRemote, addElements, setViewport, setTool, setTheme, exportImage, bounds, flushNow, revert, debugRect, debugArrow, debugSkeleton, snapshot };

// MARK: JS → Swift

function flush() {
  state.flushTimer = null;
  if (!state.pending.size || !state.api) return;
  const elements = [...state.pending.values()];
  state.pending.clear();
  const app = state.api.getAppState();
  post({
    type: "change",
    elements: JSON.parse(JSON.stringify(elements)),
    appState: { viewBackgroundColor: app.viewBackgroundColor, gridSize: app.gridSize ?? null },
  });
}

function onChange(elements, appState, files) {
  if (!state.loaded && state.api && appState && !appState.isLoading) queueMicrotask(sceneLoaded);
  if (state.loaded && appState) {
    if (appState.penMode) {
      queueMicrotask(() => state.api?.updateScene({ appState: { penMode: false }, captureUpdate: CaptureUpdateAction.NEVER }));
    }
    // Keep the host's toolbar in step with the editor (keyboard letters, the editor going back
    // to selection after text).
    const type = appState.activeTool?.type;
    if (type && type !== state.reportedTool && !pencilFallback) {
      state.reportedTool = type;
      state.tool = type;
      post({ type: "tool", tool: type });
    }
  }
  for (const el of elements) {
    if ((state.known.get(el.id) ?? -1) < el.version) {
      state.known.set(el.id, el.version);
      state.pending.set(el.id, el);
    }
  }
  const added = Object.values(files || {}).filter((f) => !state.files.has(f.id));
  if (added.length) {
    for (const f of added) state.files.add(f.id);
    post({ type: "files", files: added.map((f) => ({ id: f.id, mimeType: f.mimeType, dataURL: f.dataURL })) });
  }
  // Excalidraw's collaboration cadence.
  if (state.pending.size && !state.flushTimer) state.flushTimer = setTimeout(flush, 50);
}

function onPointerUpdate({ pointer }) {
  const now = Date.now();
  if (now - state.lastPointer < 100) return;
  state.lastPointer = now;
  post({ type: "pointer", x: pointer.x, y: pointer.y, tool: pointer.tool });
}

// The overlay's viewport belongs to the terminal: Excalidraw must not pan or zoom it.
function onScrollChange(scrollX, scrollY, zoom) {
  const v = state.viewport;
  if (state.config?.mode !== "overlay" || !v) return;
  const want = { x: v.originX / v.zoom, y: v.originY / v.zoom };
  if (Math.abs(scrollX - want.x) > 0.01 || Math.abs(scrollY - want.y) > 0.01 || Math.abs(zoom.value - v.zoom) > 1e-4) {
    queueMicrotask(applyViewport);
  }
}

// Over the overlay, wheel and trackpad scrolling scroll the terminal underneath (the host
// moves the viewport with it), so ink stays on its rows.
window.addEventListener(
  "wheel",
  (e) => {
    if (state.config?.mode !== "overlay") return;
    e.preventDefault();
    e.stopPropagation();
    post({ type: "wheel", dx: e.deltaX, dy: e.deltaY, mode: e.deltaMode });
  },
  { capture: true, passive: false },
);

// Two fingers scroll the terminal (the host's pan): the editor never sees a second finger (no
// pinch zoom, no pan), and whatever the first finger started is removed when they lift. With
// Select, a Pencil that reaches the page (the host could not tell it from a finger) draws with
// freedraw for that stroke: the Pencil always draws.
const touches = new Set();
let multi = null;
let pencilFallback = false;

function overlayPointerDown(e) {
  if (state.config?.mode !== "overlay" || !state.api) return;
  if (e.pointerType === "pen" && state.api.getAppState().activeTool.type === "selection") {
    pencilFallback = true;
    flushSync(() => state.api.setActiveTool({ type: "freedraw" }));
    post({ type: "log", message: "pencil reached the page with Select: freedraw for this stroke" });
  }
  if (e.pointerType !== "touch") return;
  touches.add(e.pointerId);
  if (touches.size === 1) {
    multi = { before: new Set(state.api.getSceneElementsIncludingDeleted().map((el) => el.id)), first: e.pointerId, active: false };
    return;
  }
  if (multi && !multi.active) {
    multi.active = true;
    post({ type: "log", message: "two fingers: the terminal scrolls" });
  }
  e.preventDefault();
  e.stopImmediatePropagation();
}

function overlayPointerMove(e) {
  if (multi?.active && e.pointerType === "touch") e.stopImmediatePropagation();
}

function overlayPointerUp(e) {
  if (e.pointerType === "pen" && pencilFallback) {
    pencilFallback = false;
    setTimeout(() => {
      state.api?.setActiveTool({ type: "selection" });
      state.reportedTool = "selection";
    }, 0);
  }
  if (e.pointerType !== "touch" || !touches.has(e.pointerId)) return;
  touches.delete(e.pointerId);
  const gesture = multi;
  if (gesture?.active && e.pointerId !== gesture.first) e.stopImmediatePropagation();
  if (touches.size) return;
  multi = null;
  if (!gesture?.active) return;
  // After the editor has finished the first finger's element.
  setTimeout(() => {
    const api = state.api;
    if (!api) return;
    let removed = 0;
    const next = api.getSceneElementsIncludingDeleted().map((el) => {
      if (gesture.before.has(el.id) || el.isDeleted) return el;
      removed++;
      return { ...el, isDeleted: true, version: el.version + 1, updated: Date.now() };
    });
    if (removed) api.updateScene({ elements: next, captureUpdate: CaptureUpdateAction.NEVER });
    if (state.tool) applyTool();
  }, 0);
}

window.addEventListener("pointerdown", overlayPointerDown, { capture: true, passive: false });
window.addEventListener("pointermove", overlayPointerMove, { capture: true });
window.addEventListener("pointerup", overlayPointerUp, { capture: true });
window.addEventListener("pointercancel", overlayPointerUp, { capture: true });
for (const type of ["gesturestart", "gesturechange", "gestureend"]) {
  window.addEventListener(
    type,
    (e) => {
      if (state.config?.mode !== "overlay") return;
      e.preventDefault();
      e.stopImmediatePropagation();
    },
    { capture: true, passive: false },
  );
}

window.addEventListener(
  "keydown",
  (e) => {
    if (state.config?.mode !== "overlay") return;
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      post({ type: "done" });
    }
    // Esc leaves draw mode (the host's Cancel), once the editor has nothing of its own to end:
    // text being typed, a shape or line being drawn, a selection. Those take Esc first, as in
    // Excalidraw. (With the keyboard focus on the host's overlay, the host handles Esc itself.)
    if (e.key === "Escape" && !e.metaKey && !e.ctrlKey && !e.altKey) {
      const app = state.api?.getAppState();
      const busy =
        !app ||
        app.editingTextElement ||
        app.newElement ||
        app.multiElement ||
        app.editingLinearElement ||
        app.selectedLinearElement?.isEditing ||
        Object.keys(app.selectedElementIds || {}).length > 0;
      if (!busy) {
        e.preventDefault();
        e.stopImmediatePropagation();
        post({ type: "cancel" });
      }
    }
  },
  { capture: true },
);

const OVERLAY_UI = {
  canvasActions: {
    changeViewBackgroundColor: false,
    clearCanvas: false,
    export: false,
    loadScene: false,
    saveAsImage: false,
    saveToActiveFile: false,
    toggleTheme: false,
  },
  tools: { image: true },
};

const CANVAS_UI = {
  canvasActions: {
    changeViewBackgroundColor: true,
    clearCanvas: true,
    export: false,
    loadScene: false,
    saveAsImage: false,
    saveToActiveFile: false,
    toggleTheme: false,
  },
  tools: { image: true },
};

function Editor() {
  const [config, set] = useState(null);
  useEffect(() => {
    setConfig = set;
    post({ type: "ready", version: VERSION });
  }, []);
  useEffect(() => {
    // Warm the hand-drawn faces so text added later (labels, remote edits) never draws in a
    // fallback serif first; Excalidraw re-renders when they finish loading.
    if (config) for (const face of ["Excalifont", "Virgil", "Nunito"]) document.fonts.load(`20px ${face}`).catch(() => {});
  }, [config]);
  if (!config) return null;
  const overlay = config.mode === "overlay";
  const v = config.viewport;
  const appState = {
    ...(config.appState || {}),
    viewBackgroundColor: "transparent",
    theme: config.theme,
    penMode: false,
    penDetected: true,
    gridModeEnabled: false,
    ...(v ? { scrollX: v.originX / v.zoom, scrollY: v.originY / v.zoom, zoom: { value: v.zoom } } : {}),
  };
  return (
    <Excalidraw
      key={config.key}
      excalidrawAPI={(api) => {
        state.api = api;
        // The scene from initialData is in once the editor stops loading.
        const check = () => {
          if (state.api !== api || state.loaded) return;
          if (api.getAppState().isLoading) requestAnimationFrame(check);
          else sceneLoaded();
        };
        requestAnimationFrame(check);
      }}
      initialData={{
        elements: restoreElements(config.elements || [], null),
        appState,
        files: Object.fromEntries((config.files || []).map((f) => [f.id, { ...f, created: Date.now() }])),
        scrollToContent: !overlay && (config.elements || []).length > 0,
      }}
      onChange={onChange}
      onPointerUpdate={onPointerUpdate}
      onScrollChange={onScrollChange}
      viewModeEnabled={!!config.readOnly}
      gridModeEnabled={false}
      theme={config.theme}
      UIOptions={overlay ? OVERLAY_UI : CANVAS_UI}
      detectScroll={false}
      handleKeyboardGlobally={true}
      autoFocus={true}
      aiEnabled={false}
    >
      <MainMenu>
        {overlay ? null : <MainMenu.DefaultItems.ClearCanvas />}
        {overlay ? null : <MainMenu.DefaultItems.ChangeCanvasBackground />}
      </MainMenu>
    </Excalidraw>
  );
}

createRoot(document.getElementById("root")).render(<Editor />);

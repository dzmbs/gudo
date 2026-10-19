// The app's Excalidraw page: the draw overlay on a terminal pane and the canvas pane.
// Bridge contract: docs/DAEMON.md §7.11. Swift → JS calls window.canvas.<fn>(json);
// JS → Swift posts to window.webkit.messageHandlers.canvas.
//
// Built by apple/scripts/build-excalidraw.sh into apple/App/Resources/Excalidraw/.

import React, { useEffect, useState } from "react";
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
};

let setConfig = () => {};

// MARK: Swift → JS

function load(config) {
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

// Ink converted from PencilKit: added as the user's own edit (undoable, posted back as a
// change), then acknowledged once drawn so the host can drop its live stroke without a gap.
function addElements({ elements = [] }) {
  const api = state.api;
  if (!api || !elements.length) return;
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

function setTool({ type }) {
  state.api?.setActiveTool({ type });
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

window.canvas = { load, applyRemote, addElements, setViewport, setTool, setTheme, exportImage, bounds, flushNow, debugRect, debugArrow, debugSkeleton, snapshot };

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

function onChange(elements, _appState, files) {
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

window.addEventListener(
  "keydown",
  (e) => {
    if (state.config?.mode !== "overlay") return;
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      post({ type: "done" });
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
    gridModeEnabled: false,
    ...(v ? { scrollX: v.originX / v.zoom, scrollY: v.originY / v.zoom, zoom: { value: v.zoom } } : {}),
  };
  return (
    <Excalidraw
      key={config.key}
      excalidrawAPI={(api) => {
        state.api = api;
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

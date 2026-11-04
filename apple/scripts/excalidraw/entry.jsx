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
  // added before that are replaced by the scene and lost).
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
  // The overlay never uses Excalidraw's pen mode: once a Pencil touched the page it stopped
  // fingers from drawing shapes (App `allowOnPointerDown`). Touch routing belongs to the host.
  if (state.config?.mode === "overlay") {
    state.api.updateScene({ appState: { penMode: false, penDetected: true }, captureUpdate: CaptureUpdateAction.NEVER });
  }
  if (state.tool) applyTool();
  postViewport();
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
  const viewport = state.viewport;
  if (!api || !viewport) return;
  api.updateScene({
    appState: { scrollX: viewport.originX / viewport.zoom, scrollY: viewport.originY / viewport.zoom, zoom: { value: viewport.zoom } },
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

// Canvas panes: once a Pencil is in use, fingers pan and zoom instead of drawing.
function setPenMode({ enabled }) {
  state.api?.updateScene({ appState: { penMode: !!enabled, penDetected: true }, captureUpdate: CaptureUpdateAction.NEVER });
}

// Where the canvas pane's scene sits in the page, for the host's Pencil layer.
function postViewport() {
  const api = state.api;
  if (!api || state.config?.mode !== "canvas") return;
  const app = api.getAppState();
  post({ type: "viewport", scrollX: app.scrollX, scrollY: app.scrollY, zoom: app.zoom.value, offsetLeft: app.offsetLeft, offsetTop: app.offsetTop });
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

// Excalidraw's dark theme is a CSS filter on the canvas (invert(93%) hue-rotate(180deg)), and
// images are pre-inverted with the canvas 2D \`filter\` so they come out as themselves. WebKit
// does not implement that \`filter\`: these apply the same color matrices to the pixels.
const HUE_ROTATE_HALF_TURN = [-0.574, 1.43, 0.144, 0.426, 0.43, 0.144, 0.426, 1.43, -0.856];
const SATURATE_125 = [1.19675, -0.17875, -0.018, 0.14675, 1.07125, -0.018, 0.14675, -0.17875, 1.232];
const IMAGE_INVERT_FILTER = "invert(100%) hue-rotate(180deg) saturate(1.25)";

function clamp(value) {
  return Math.max(0, Math.min(1, value));
}

function multiply(matrix, r, g, b) {
  return [
    clamp(matrix[0] * r + matrix[1] * g + matrix[2] * b),
    clamp(matrix[3] * r + matrix[4] * g + matrix[5] * b),
    clamp(matrix[6] * r + matrix[7] * g + matrix[8] * b),
  ];
}

function filterPixels(pixels, invertAmount, saturate) {
  const invert = (channel) => invertAmount - (2 * invertAmount - 1) * (channel / 255);
  for (let i = 0; i < pixels.length; i += 4) {
    if (pixels[i + 3] === 0) continue;
    let rgb = multiply(HUE_ROTATE_HALF_TURN, invert(pixels[i]), invert(pixels[i + 1]), invert(pixels[i + 2]));
    if (saturate) rgb = multiply(SATURATE_125, ...rgb);
    pixels[i] = rgb[0] * 255;
    pixels[i + 1] = rgb[1] * 255;
    pixels[i + 2] = rgb[2] * 255;
  }
}

function canvasFiltersWork() {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext("2d");
  ctx.filter = "invert(100%)";
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, 1, 1);
  return ctx.getImageData(0, 0, 1, 1).data[0] > 127;
}

const nativeCanvasFilters = canvasFiltersWork();
// A dark export draws its images unfiltered under a filter on the whole canvas, which
// `finishExport` applies afterwards here: they are pre-inverted as the editor draws them.
let exportingDark = false;

// A pasted screenshot on a dark canvas shows as itself, not as its negative.
if (!nativeCanvasFilters) {
  const inverted = new WeakMap();
  const drawImage = CanvasRenderingContext2D.prototype.drawImage;
  const invertedCopy = (source) => {
    const width = source.naturalWidth;
    const height = source.naturalHeight;
    if (!width || !height) return source;
    const cached = inverted.get(source);
    if (cached?.width === width && cached?.height === height) return cached;
    const copy = document.createElement("canvas");
    copy.width = width;
    copy.height = height;
    const ctx = copy.getContext("2d");
    drawImage.call(ctx, source, 0, 0, width, height);
    const image = ctx.getImageData(0, 0, width, height);
    filterPixels(image.data, 1, true);
    ctx.putImageData(image, 0, 0);
    inverted.set(source, copy);
    return copy;
  };
  CanvasRenderingContext2D.prototype.drawImage = function (source, ...rest) {
    const invert = this.filter === IMAGE_INVERT_FILTER || exportingDark;
    if (!invert || !(source instanceof HTMLImageElement)) return drawImage.call(this, source, ...rest);
    return drawImage.call(this, invertedCopy(source), ...rest);
  };
}

// The exported PNG as the editor shows it: the dark theme's filter, then the pane's background
// under the drawing, which is what the canvas stands on.
async function finishExport(blob, { dark, backgroundColor }) {
  if (!dark && !backgroundColor) return blob;
  const bitmap = await createImageBitmap(blob);
  const canvas = document.createElement("canvas");
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bitmap, 0, 0);
  if (dark) {
    const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
    filterPixels(image.data, 0.93, false);
    ctx.putImageData(image, 0, 0);
  }
  if (backgroundColor) {
    ctx.globalCompositeOperation = "destination-over";
    ctx.fillStyle = backgroundColor;
    ctx.fillRect(0, 0, canvas.width, canvas.height);
  }
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

async function exportImage({ requestId, format = "png", scale = 2, exportPadding = 0, bounds = null, background = false, backgroundColor = null, selectionOnly = false }) {
  const api = state.api;
  if (!api) return post({ type: "export", requestId, error: "not loaded" });
  try {
    const scene = api.getSceneElements();
    const selected = api.getAppState().selectedElementIds || {};
    const picked = selectionOnly ? scene.filter((e) => selected[e.id]) : [];
    const drawn = picked.length ? picked : scene;
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
      const dark = appState.exportWithDarkMode && !nativeCanvasFilters;
      exportingDark = dark;
      let blob;
      try {
        blob = await exportToBlob({
          elements,
          appState,
          files,
          exportPadding,
          mimeType: "image/png",
          getDimensions: (width, height) => ({ width: width * scale, height: height * scale, scale }),
        });
      } finally {
        exportingDark = false;
      }
      data = await blobToBase64(await finishExport(blob, { dark, backgroundColor }));
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

function bytes(base64) {
  const binary = atob(base64);
  const array = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) array[i] = binary.charCodeAt(i);
  return array;
}

function isWritable(element) {
  return element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement || !!element?.isContentEditable;
}

const pointer = { x: null, y: null };
document.addEventListener(
  "pointermove",
  (event) => {
    pointer.x = event.clientX;
    pointer.y = event.clientY;
  },
  { capture: true, passive: true },
);

// Excalidraw pastes where the pointer last was, and only over its canvas: with the pointer
// elsewhere, or never seen (a keyboard paste on touch), it goes to the middle of the view.
function pointAtCanvas() {
  if (pointer.x !== null && document.elementFromPoint(pointer.x, pointer.y) instanceof HTMLCanvasElement) return;
  const canvas = document.querySelector(".excalidraw canvas.interactive") || document.querySelector(".excalidraw canvas");
  if (!canvas) return;
  const rect = canvas.getBoundingClientRect();
  document.dispatchEvent(new PointerEvent("pointermove", { clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 }));
}

// ⌘V and Paste: the host reads the system clipboard (the page cannot) and hands it over, and
// Excalidraw takes it as its own paste (images, text, copied shapes).
function paste(contents = {}) {
  if (!state.api || state.config?.readOnly) return;
  if (isWritable(document.activeElement)) {
    if (contents.text) document.execCommand("insertText", false, contents.text);
    return;
  }
  const data = new DataTransfer();
  if (contents.image) data.items.add(new File([bytes(contents.image)], "Pasted Image", { type: contents.mimeType || "image/png" }));
  if (contents.text) data.setData("text/plain", contents.text);
  if (!data.items.length) return;
  const container = document.querySelector(".excalidraw-container");
  if (container && !container.contains(document.activeElement)) container.focus();
  pointAtCanvas();
  document.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
}

// Excalidraw's own Paste (its context menu) reads the clipboard through the host too.
function hostClipboard() {
  const handler = window.webkit?.messageHandlers?.canvasClipboard;
  return handler ? handler.postMessage({}).then((contents) => contents || {}) : Promise.resolve({});
}

{
  const existing = navigator.clipboard;
  const clipboard = {
    async read() {
      const contents = await hostClipboard();
      const blobs = {};
      if (contents.image) {
        const type = contents.mimeType || "image/png";
        blobs[type] = new Blob([bytes(contents.image)], { type });
      }
      if (contents.text) blobs["text/plain"] = new Blob([contents.text], { type: "text/plain" });
      const types = Object.keys(blobs);
      return types.length ? [{ types, getType: async (type) => blobs[type] }] : [];
    },
    async readText() {
      return (await hostClipboard()).text || "";
    },
  };
  if (existing?.writeText) clipboard.writeText = existing.writeText.bind(existing);
  if (existing?.write) clipboard.write = existing.write.bind(existing);
  Object.defineProperty(navigator, "clipboard", { value: clipboard, configurable: true });
}

// Debug and tests: the scene as the editor holds it.
function snapshot() {
  const api = state.api;
  return JSON.stringify({
    elements: api ? api.getSceneElements() : [],
    tool: api?.getAppState().activeTool.type,
    files: api ? Object.keys(api.getFiles()) : [],
  });
}

window.canvas = { load, applyRemote, addElements, setViewport, setTool, setTheme, setPenMode, exportImage, paste, bounds, flushNow, revert, debugRect, debugArrow, debugSkeleton, snapshot };

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
    if (appState.penMode && state.config?.mode === "overlay") {
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
  if (state.config?.mode === "canvas") {
    queueMicrotask(postViewport);
    return;
  }
  const viewport = state.viewport;
  if (state.config?.mode !== "overlay" || !viewport) return;
  const want = { x: viewport.originX / viewport.zoom, y: viewport.originY / viewport.zoom };
  if (Math.abs(scrollX - want.x) > 0.01 || Math.abs(scrollY - want.y) > 0.01 || Math.abs(zoom.value - viewport.zoom) > 1e-4) {
    queueMicrotask(applyViewport);
  }
}

// Over the overlay, wheel and trackpad scrolling scroll the terminal underneath (the host
// moves the viewport with it), so ink stays on its rows.
window.addEventListener(
  "wheel",
  (event) => {
    if (state.config?.mode !== "overlay") return;
    event.preventDefault();
    event.stopPropagation();
    post({ type: "wheel", dx: event.deltaX, dy: event.deltaY, mode: event.deltaMode });
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

function overlayPointerDown(event) {
  if (state.config?.mode !== "overlay" || !state.api) return;
  if (event.pointerType === "pen" && state.api.getAppState().activeTool.type === "selection") {
    pencilFallback = true;
    flushSync(() => state.api.setActiveTool({ type: "freedraw" }));
    post({ type: "log", message: "pencil reached the page with Select: freedraw for this stroke" });
  }
  if (event.pointerType !== "touch") return;
  touches.add(event.pointerId);
  if (touches.size === 1) {
    multi = { before: new Set(state.api.getSceneElementsIncludingDeleted().map((el) => el.id)), first: event.pointerId, active: false };
    return;
  }
  if (multi && !multi.active) {
    multi.active = true;
    post({ type: "log", message: "two fingers: the terminal scrolls" });
  }
  event.preventDefault();
  event.stopImmediatePropagation();
}

function overlayPointerMove(event) {
  if (multi?.active && event.pointerType === "touch") event.stopImmediatePropagation();
}

function overlayPointerUp(event) {
  if (event.pointerType === "pen" && pencilFallback) {
    pencilFallback = false;
    setTimeout(() => {
      state.api?.setActiveTool({ type: "selection" });
      state.reportedTool = "selection";
    }, 0);
  }
  if (event.pointerType !== "touch" || !touches.has(event.pointerId)) return;
  touches.delete(event.pointerId);
  const gesture = multi;
  if (gesture?.active && event.pointerId !== gesture.first) event.stopImmediatePropagation();
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
    (event) => {
      if (state.config?.mode !== "overlay") return;
      event.preventDefault();
      event.stopImmediatePropagation();
    },
    { capture: true, passive: false },
  );
}

window.addEventListener(
  "keydown",
  (event) => {
    if (state.config?.mode !== "overlay") return;
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      post({ type: "done" });
    }
    // Esc leaves draw mode (the host's Cancel), once the editor has nothing of its own to end:
    // text being typed, a shape or line being drawn, a selection. Those take Esc first, as in
    // Excalidraw. (With the keyboard focus on the host's overlay, the host handles Esc itself.)
    if (event.key === "Escape" && !event.metaKey && !event.ctrlKey && !event.altKey) {
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
        event.preventDefault();
        event.stopImmediatePropagation();
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
  const viewport = config.viewport;
  const appState = {
    ...(config.appState || {}),
    viewBackgroundColor: "transparent",
    theme: config.theme,
    penMode: false,
    penDetected: true,
    gridModeEnabled: false,
    ...(viewport ? { scrollX: viewport.originX / viewport.zoom, scrollY: viewport.originY / viewport.zoom, zoom: { value: viewport.zoom } } : {}),
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

// The editor measures its offsets after a resize; the host's Pencil layer needs them.
window.addEventListener("resize", () => setTimeout(postViewport, 100));

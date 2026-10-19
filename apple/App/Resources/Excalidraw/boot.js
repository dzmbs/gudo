// Fonts load from the bundle next to this page (the app's custom scheme), never from a CDN.
window.EXCALIDRAW_ASSET_PATH = new URL("./", window.location.href).href;
window.process = { env: { NODE_ENV: "production" } };

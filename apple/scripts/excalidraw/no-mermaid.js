// Mermaid → Excalidraw (the "text to diagram" dialog) is not offered in the app; aliasing it
// out keeps ~3 MB of mermaid, cytoscape and katex out of the offline bundle.
export async function parseMermaidToExcalidraw() {
  throw new Error("Mermaid import is not available in this build");
}

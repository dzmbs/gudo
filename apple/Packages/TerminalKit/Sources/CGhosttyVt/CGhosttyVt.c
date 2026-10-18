// CGhosttyVt only re-exports the libghostty-vt headers (include/ghostty -> vendor/ghostty/include).
// SwiftPM's build backend requires every C target to produce an object file, so this translation
// unit exists to compile the umbrella header once (which also catches header breakage early).
#include <ghostty/vt.h>

// rrweb's recorder for session replay (BrowserRecording), as one global.
import { record } from '@rrweb/record';

(globalThis as any).__gudoRRWeb = { record };

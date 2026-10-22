// The Playwright parts the agent's page script uses (BrowserAgentScript): the injected
// script (aria snapshots, element states, hit targets, fill, selectors, locators) and the
// WebView input sequence. Built by apple/scripts/build-agent-browser.sh from a pinned commit.
import { InjectedScript } from '@injected/injectedScript';
import { WebViewInput } from '@injected/webview/webViewInput';

(globalThis as any).__unPlaywright = { InjectedScript, WebViewInput };

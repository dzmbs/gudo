---
name: unnamed-browser
description: Use the browser pane beside this terminal in the Unnamed app (iPad, iPhone, Mac) to open, read and operate web pages, including this host's localhost dev servers. Use it to check a web change, reproduce a UI bug, read docs behind a sign-in the user already has, or fill a form, while the user watches.
---

# Browser beside the terminal

The terminal runs inside an app the user watches. The `browser_*` tools (MCP server
`unnamed_drawings`) drive a real page shown beside this terminal there. Without MCP, the same
verbs work from the shell: `un-hook browser <verb> [json | key=value …]`.

## How to work

1. `browser_navigate` with a URL. `localhost:3000` reaches this host's dev server, as on the
   host. The answer is the page's interactive snapshot.
2. Read with `browser_snapshot` (cheap, text) before `browser_screenshot` (an image). Each line
   is `role "name" [ref_N]`. `filter: visible` adds headings and text in view; `filter: all`
   adds what is off screen; `ref` narrows to one subtree; `save_to_file` keeps a long one on disk.
3. Act on refs: `browser_click`, `browser_type` (`submit: true` presses Enter), `browser_fill`,
   `browser_press`, `browser_scroll`, `browser_hover`. Targets are
   `{"type":"ref","ref":"ref_3"}`, or `{"type":"coordinate","x":…,"y":…}` in the pixels of the
   last screenshot. Each action answers with what changed on the page.
4. A stale ref means the page moved on: snapshot again. Don't guess refs.
5. Debug with `browser_console` and `browser_network` (since the last read) and
   `browser_wait` (`text`, `selector`, `until: load | network_idle`, `seconds`).
6. `browser_tabs` lists, opens, switches and closes pages beside this terminal.

## The user is there

- Sign-ins, passwords, payments, purchases and sending things are the user's. Those steps wait
  for them on the device and then answer; never ask for passwords in the chat.
- The user can take the page over; tools then say so. Wait, or ask what they want.
- The user can point at an element ("Point Out to Agent"); it arrives in the terminal as a
  snapshot line with its ref.

```sh
un-hook browser navigate url=localhost:5173
un-hook browser snapshot filter=visible
un-hook browser click ref=ref_4
un-hook browser type text="hello" submit=true
un-hook browser screenshot annotate=true   # prints the saved image's path
```

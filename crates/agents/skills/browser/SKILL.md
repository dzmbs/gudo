---
name: gudo-browser
description: Use the browser pane beside this terminal in the Gudo app (iPad, iPhone, Mac) to open, read and operate web pages, including this host's localhost dev servers. Use it to check a web change, reproduce a UI bug, read docs behind a sign-in the user already has, or fill a form, while the user watches.
---

# Browser beside the terminal

The terminal runs inside an app the user watches. The `browser_*` tools (MCP server
`gudo`) drive a real page shown beside this terminal there. Without MCP, the same
verbs work from the shell: `gudo-hook browser <verb> [json | key=value …]`.

## How to work

1. `browser_navigate` with a URL. `localhost:3000` reaches this host's dev server, as on the
   host. It waits for the page to load and answers with its interactive snapshot.
2. Read with `browser_snapshot` (cheap, text) before `browser_screenshot` (an image). Each line
   is `role "name" = "value" (states) [ref_N]`; `[cursor=pointer]` marks other clickable
   elements. A frame's elements follow its iframe, with refs like `ref_f1_3`. `filter: visible`
   adds headings and text in view; `filter: all` adds what is off screen; `ref` narrows to one
   subtree; `save_to_file` keeps a long one on disk. After the first snapshot only changes are
   listed: `*` a new element, `+` changed, `-` gone.
3. Act on refs: `browser_click`, `browser_type` (key by key; `submit: true` presses Enter),
   `browser_fill` (replaces a field's value; checkboxes take true/false, selects an option),
   `browser_press`, `browser_scroll`, `browser_hover`. Targets are
   `{"type":"ref","ref":"ref_3"}`, or `{"type":"coordinate","x":…,"y":…}` in the pixels of the
   last screenshot.
4. Each action waits until its element is visible, enabled and not covered, then waits for what
   it started (a navigation, requests, the page settling) and says what changed.
   - "covered by …": close that banner or dialog first (it is in the snapshot), or scroll.
   - "No observable effect": the site may ignore script input. Focus the control and
     `browser_press` Enter or Space, click coordinates from a screenshot, or ask the user to tap.
   - `force: true` skips the checks.
5. A ref whose element was re-rendered is found again by its role and name; a stale ref means
   the page moved on: snapshot again. Don't guess refs.
6. Dialogs (alert, confirm, prompt, and "Leave site?" when navigating away from unsaved changes)
   hold the page until `browser_dialog` answers them. Pages
   opened in a new window become tabs: `browser_tabs` lists, opens, switches and closes them
   (ids `t1`, `t2`, …). `browser_upload` chooses files in this project for a file field, or for
   the file picker an action opened; the user approves each upload on the device.
7. Debug with `browser_console` and `browser_network` (since the last read) and
   `browser_wait` (`text`, `selector`, `until: load | network_idle`, `seconds`).

## The user is there

- Sign-ins, passwords, payments, purchases and sending things are the user's. Those steps wait
  for them on the device and then answer; never ask for passwords in the chat.
- The user can take the page over; tools then say so. Wait, or ask what they want.
- The user can point at an element ("Point Out to Agent"); it arrives in the terminal as a
  snapshot line with its ref.

```sh
gudo-hook browser navigate url=localhost:5173
gudo-hook browser snapshot filter=visible
gudo-hook browser click ref=ref_4
gudo-hook browser type text="hello" submit=true
gudo-hook browser dialog accept=true
gudo-hook browser screenshot annotate=true   # prints the saved image's path
```

# Run a dev server and check the page

The user asks you to fix a layout bug on the sign-up page and check it in the browser.

Start the server in a pane of its own, so its log stays visible, and wait for the line that
names its port:

```text
cmd_run {"command": "npm run dev", "timeoutMs": 2000}
pane_wait {"pane": "p8", "match": "localhost:(\\d+)", "timeoutMs": 60000}
```

`cmd_run` comes back with `timeout` because the server keeps running; that is expected. The
match returns the port in its groups. Open the page beside the terminal and read it as text:

```text
browser_navigate {"url": "localhost:5173/signup"}
browser_snapshot {"filter": "visible"}
browser_screenshot {"annotate": true}
```

Fix the code, then check again. The server reloads by itself; read only the log since your last
cursor, and the page's errors:

```text
pane_read {"pane": "p8", "since": "c48213", "grep": "error|warn"}
browser_navigate {"url": "reload"}
browser_console {}
```

Try the form as a user would, without real personal data:

```text
browser_fill {"target": {"type": "ref", "ref": "ref_5"}, "value": "test@example.com"}
browser_click {"target": {"type": "ref", "ref": "ref_9"}}
```

If the page asks for a real sign-in or a payment, stop: that is the user's. When you are done,
stop the server (or tell the user it is still running in `p8` if they want it), and close what
you opened:

```text
pane_send {"pane": "p8", "keys": ["ctrl+c"]}
pane_close {"pane": "p8"}
```

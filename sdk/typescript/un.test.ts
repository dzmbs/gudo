// The client against a fake hook socket: the line it sends, typed results and errors, and an
// event stream that refuses to skip lost events. `crates/daemon/tests/it/drive.rs` runs it
// against a real daemon too.

import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:net";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { EventsLost, TermError, Terminal } from "./un.ts";

/** A hook socket that answers each line with `answer(call)`. */
async function fake(answer: (call: any) => unknown): Promise<{ socket: string; calls: any[]; server: Server }> {
  const socket = join(mkdtempSync(join(tmpdir(), "un-sdk-")), "hook.sock");
  const calls: any[] = [];
  const server = createServer((conn) => {
    let line = "";
    conn.setEncoding("utf8");
    conn.on("data", (chunk: string) => {
      line += chunk;
      if (!line.includes("\n")) return;
      const call = JSON.parse(line);
      calls.push(call);
      conn.end(JSON.stringify(answer(call)) + "\n");
    });
  });
  await new Promise<void>((resolve) => server.listen(socket, resolve));
  return { socket, calls, server };
}

test("a call is one line as the pane, and its result comes back typed", async () => {
  const { socket, calls, server } = await fake(() => ({ ok: { pane: "p7", status: "exited", command: { exitCode: 3 } } }));
  const term = Terminal.fromEnv({ UN_SOCK: socket, UN_TOKEN: "t0k", UN_PANE_ID: "4" });
  const run = await term.run("make", { timeoutMs: 1000 });
  assert.equal(run.command?.exitCode, 3);
  assert.deepEqual(calls[0], {
    v: 1,
    token: "t0k",
    pane: "4",
    term: { tool: "cmd_run", args: { command: "make", timeoutMs: 1000 } },
  });
  server.close();
});

test("refusals are TermErrors with the daemon's code and hint", async () => {
  const { socket, server } = await fake(() => ({
    error: { code: "forbidden", message: "the user said no", retryable: false, hint: "ask them" },
  }));
  const term = new Terminal({ socket, token: "t", pane: "1" });
  await assert.rejects(term.panes.send("p2", { text: "x" }), (e: unknown) => {
    assert.ok(e instanceof TermError);
    assert.equal(e.code, "forbidden");
    assert.equal(e.hint, "ask them");
    return true;
  });
  server.close();
});

test("events follow the cursor and lost events are an error, not a gap", async () => {
  let page = 0;
  const { socket, calls, server } = await fake(() => {
    page += 1;
    if (page === 1) {
      return { ok: { events: [{ v: 1, seq: 4, at: 0, type: "pane.opened", pane: "p9" }], cursor: 5 } };
    }
    return { ok: { events: [{ v: 1, seq: 9, at: 0, type: "events.lost", missed: 3 }], cursor: 12 } };
  });
  const term = new Terminal({ socket, token: "t", pane: "1" });
  const seen: string[] = [];
  await assert.rejects(
    (async () => {
      for await (const event of term.events({ types: ["pane.opened"] })) seen.push(`${event.type} ${event.pane}`);
    })(),
    (e: unknown) => e instanceof EventsLost && e.missed === 3,
  );
  assert.deepEqual(seen, ["pane.opened p9"]);
  assert.equal(calls[1].term.args.since, 5, "the second read starts at the first's cursor");
  server.close();
});

test("outside a pane there is nothing to act as", () => {
  assert.throws(() => Terminal.fromEnv({}), /not in a pane/);
});

// A typed client for the terminal tools, for scripts that run in a pane (Node ≥ 22.18, Bun,
// Deno). It speaks the hook socket's line protocol directly: one JSON line per call. The pane
// is the caller, proven by its own token, so a script has exactly an agent's rights: it drives
// the panes it opens, and the user's panes only once the owner allows it.
//
//   import { Terminal } from "./gudo.ts";
//   const term = Terminal.fromEnv();
//   const { pane } = await term.run("cargo test");
//   for await (const event of term.events({ types: ["command.finished"] })) { … }
//
// Schema: docs/DAEMON.md ("Terminal tools", "Scripting"). No dependencies.

import { connect } from "node:net";
import { readFileSync } from "node:fs";

/** The terminal tools' protocol version. */
export const TERM_VERSION = 1;

/** Why a call did nothing (`TermReply::Error`). */
export class TermError extends Error {
  readonly code: ErrorCode;
  readonly retryable: boolean;
  readonly hint?: string;

  constructor(code: ErrorCode, message: string, retryable: boolean, hint?: string) {
    super(message);
    this.name = "TermError";
    this.code = code;
    this.retryable = retryable;
    this.hint = hint;
  }
}

/** The subscriber fell behind and events were dropped: what it knew may be stale. */
export class EventsLost extends Error {
  readonly missed: number;

  constructor(missed: number) {
    super(`${missed} events were lost`);
    this.name = "EventsLost";
    this.missed = missed;
  }
}

export type ErrorCode =
  | "invalid_args"
  | "not_found"
  | "forbidden"
  | "pane_busy"
  | "secret_prompt"
  | "cursor_expired"
  | "closed"
  | "agent_blocked"
  | "agent_busy"
  | "failed";

/** A pane id, `p12`. */
export type PaneRef = string;

export interface Output {
  text: string;
  cursor: string;
  truncated?: boolean;
  source?: string;
}

export interface Command {
  id: number;
  pane: PaneRef;
  command?: string;
  cwd?: string;
  status: "running" | "exited";
  exitCode?: number;
  durationMs?: number;
}

export interface Pane {
  id: PaneRef;
  tab?: string;
  title: string;
  cwd?: string;
  kind: "shell" | "command" | "agent";
  isSelf: boolean;
  createdByYou: boolean;
  /** `ask`: input and closing need the user's yes first. */
  scopes: Array<"read" | "input" | "manage" | "ask">;
  atPrompt: boolean;
  altScreen: boolean;
  secretPrompt: boolean;
  exited: boolean;
  /** `tmux`, `screen`, `zellij` or `byobu` runs there (`tmux-control`: `tmux -CC`). */
  multiplexer?: string | null;
  lastCommand?: Command;
  cursor: string;
}

/** The visible screen of a full-screen program. Rows count from 0 at the top. */
export interface Screen {
  cols: number;
  rows: number;
  cursor: { row: number; col: number; visible: boolean };
  /** Runs set apart by reverse video or their own background: selected items, status bars. */
  highlights: Array<{ row: number; col: number; text: string; inverse: boolean }>;
}

export interface RunResult {
  pane: PaneRef;
  status: "exited" | "timeout" | "unknown";
  command?: Command;
  output?: Output;
}

export interface WaitResult {
  status: "matched" | "gone" | "prompt" | "exited" | "quiet" | "status" | "closed" | "timeout";
  output: Output;
  screen?: Screen;
  match?: { line: string; groups: Array<string | null> };
  command?: Command;
}

/** One event (`proto::script`, version 1). Unknown types may appear: ignore them. */
export type ScriptEvent = {
  v: number;
  seq: number;
  at: number;
  session?: string;
  pane?: PaneRef;
} & (
  | { type: "pane.opened"; tab?: string }
  | { type: "pane.closed" }
  | { type: "command.started"; id: number; command?: string; cwd?: string }
  | { type: "command.finished"; id: number; command?: string; exitCode?: number; durationMs: number }
  | { type: "agent.state"; state: string; kind?: string; app?: string }
  | { type: "layout.changed" }
  | { type: "events.lost"; missed: number }
);

export type EventType = ScriptEvent["type"];

export interface TerminalOptions {
  /** The hook socket. */
  socket: string;
  /** The pane's own token (`GUDO_TOKEN`). */
  token: string;
  /** The pane's id (`GUDO_PANE_ID`). */
  pane: string;
}

/** The terminal tools, as the pane the script runs in. */
export class Terminal {
  readonly #options: TerminalOptions;

  constructor(options: TerminalOptions) {
    this.#options = options;
  }

  /** From the pane's environment: `GUDO_ENDPOINT_FILE` or `GUDO_SOCK`, `GUDO_TOKEN`, `GUDO_PANE_ID`. */
  static fromEnv(env: Record<string, string | undefined> = process.env): Terminal {
    const file = env.GUDO_ENDPOINT_FILE;
    const socket = file ? readFileSync(file, "utf8").trim() : env.GUDO_SOCK;
    const { GUDO_TOKEN: token, GUDO_PANE_ID: pane } = env;
    if (!socket || !token || !pane) {
      throw new Error("not in a pane: GUDO_SOCK (or GUDO_ENDPOINT_FILE), GUDO_TOKEN and GUDO_PANE_ID are needed");
    }
    return new Terminal({ socket, token, pane });
  }

  /** Calls tool `tool`; resolves with its result or rejects with a {@link TermError}. */
  call<T = unknown>(tool: string, args: Record<string, unknown> = {}): Promise<T> {
    const line = JSON.stringify({
      v: TERM_VERSION,
      token: this.#options.token,
      pane: this.#options.pane,
      term: { tool, args },
    });
    return new Promise((resolve, reject) => {
      const socket = connect(this.#options.socket);
      let answer = "";
      socket.setEncoding("utf8");
      socket.on("connect", () => socket.write(line + "\n"));
      socket.on("data", (chunk: string) => {
        answer += chunk;
        const end = answer.indexOf("\n");
        if (end < 0) return;
        socket.destroy();
        try {
          const reply = JSON.parse(answer.slice(0, end));
          if ("ok" in reply) {
            resolve(reply.ok as T);
          } else {
            const { code, message, retryable, hint } = reply.error;
            reject(new TermError(code, message, retryable, hint));
          }
        } catch (parseError) {
          reject(parseError);
        }
      });
      socket.on("error", reject);
      socket.on("close", () => reject(new Error("the daemon closed the connection")));
    });
  }

  whoami(): Promise<{ pane: Pane; session?: { id: string; name: string }; host: string; protocol: number }> {
    return this.call("whoami");
  }

  /** Runs `command` and waits for its exit code; without `pane`, in a new pane of its own. */
  run(command: string, options: { pane?: PaneRef; cwd?: string; timeoutMs?: number; maxBytes?: number } = {}): Promise<RunResult> {
    return this.call("cmd_run", { command, ...options });
  }

  readonly panes = {
    list: (scope: "tab" | "session" = "session"): Promise<Pane[]> =>
      this.call<{ panes: Pane[] }>("pane_list", { scope }).then((result) => result.panes),
    split: (options: { of?: PaneRef; direction?: "right" | "down"; cwd?: string; command?: string; agent?: "claude" | "codex"; focus?: boolean } = {}): Promise<Pane> =>
      this.call<{ pane: Pane }>("pane_split", options).then((result) => result.pane),
    read: (pane: PaneRef, options: { since?: string; command?: number | "last"; screen?: boolean; tail?: number; grep?: string; context?: number; maxBytes?: number } = {}) =>
      this.call<{ output: Output; altScreen: boolean; atPrompt: boolean; command?: Command; screen?: Screen }>("pane_read", { pane, ...options }),
    wait: (pane: PaneRef, until: { match?: string; screen?: boolean; gone?: boolean; since?: string; prompt?: boolean; quietMs?: number; exit?: number; status?: string[]; timeoutMs?: number; maxBytes?: number }): Promise<WaitResult> =>
      this.call("pane_wait", { pane, ...until }),
    /** In a pane the user opened, waits for the user's yes. */
    send: (pane: PaneRef, input: { text?: string; keys?: string[]; submit?: boolean }) =>
      this.call<{ written: number; cursor: string }>("pane_send", { pane, ...input }),
    close: (pane: PaneRef) => this.call<{ closed: boolean; alreadyClosed: boolean }>("pane_close", { pane }),
  };

  readonly agents = {
    spawn: (kind: "claude" | "codex", options: { prompt?: string; cwd?: string; of?: PaneRef; direction?: "right" | "down"; timeoutMs?: number } = {}) =>
      this.call<{ agent: unknown }>("agent_spawn", { kind, ...options }),
    prompt: (pane: PaneRef, text: string, options: { wait?: boolean; timeoutMs?: number } = {}) =>
      this.call<unknown>("agent_prompt", { pane, text, ...options }),
    wait: (panes: PaneRef[], options: { until?: string[]; all?: boolean; timeoutMs?: number } = {}) =>
      this.call<{ status: "ok" | "timeout"; agents: unknown[] }>("agent_wait", { panes, ...options }),
    result: (pane: PaneRef) => this.call<unknown>("agent_result", { pane }),
  };

  /**
   * The session's events from now (or `since`), as they happen. Throws {@link EventsLost}
   * when some were dropped before they were read, rather than skipping them silently.
   */
  async *events(options: { types?: EventType[]; since?: number; signal?: AbortSignal } = {}): AsyncGenerator<ScriptEvent> {
    let since = options.since;
    while (!options.signal?.aborted) {
      const page = await this.call<{ events: ScriptEvent[]; cursor: number }>("events_wait", {
        since,
        types: options.types ?? [],
        timeoutMs: 30_000,
      });
      since = page.cursor;
      for (const event of page.events) {
        if (event.type === "events.lost") throw new EventsLost(event.missed);
        yield event;
      }
    }
  }
}

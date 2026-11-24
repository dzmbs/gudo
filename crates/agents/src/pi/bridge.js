// Connects a pi the helper launched to the helper, beside its terminal UI: Chat sees what pi
// streams and can prompt, steer, stop and change the model through pi's own extension API.
// The helper writes this file and passes it with `--extension`; it is inert anywhere else.

const net = require("node:net");
const fs = require("node:fs");

const ENV_PANE = "@PANE_ID@";
const ENV_TOKEN = "@TOKEN@";
const ENV_SOCK = "@SOCK@";
const ENV_ENDPOINT_FILE = "@ENDPOINT_FILE@";
const PROTOCOL = 1;
const RETRY_FIRST_MS = 250;
const RETRY_LAST_MS = 5000;
const LINE_LIMIT = 8 * 1024 * 1024;
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

function socketPath() {
  const endpoint = process.env[ENV_ENDPOINT_FILE];
  if (endpoint) {
    try {
      const path = fs.readFileSync(endpoint, "utf8").trim();
      if (path) return path;
    } catch {}
  }
  return process.env[ENV_SOCK];
}

module.exports = function gudoBridge(pi) {
  const pane = process.env[ENV_PANE];
  const token = process.env[ENV_TOKEN];
  if (!pane || !token) return;

  let context;
  let socket;
  let ending = false;
  let retryMs = RETRY_FIRST_MS;
  let retryTimer;
  let pending = "";

  function send(message) {
    if (!socket || socket.destroyed || !socket.gudoReady) return;
    try {
      socket.write(JSON.stringify(message) + "\n");
    } catch {}
  }

  function modelOf(model) {
    if (!model) return null;
    return {
      provider: String(model.provider ?? ""),
      id: String(model.id ?? ""),
      name: String(model.name ?? model.id ?? ""),
      reasoning: Boolean(model.reasoning),
    };
  }

  function thinkingLevels(model) {
    return model && model.reasoning ? THINKING_LEVELS : ["off"];
  }

  function session() {
    const manager = context?.sessionManager;
    let thinking = null;
    try {
      thinking = pi.getThinkingLevel();
    } catch {}
    return {
      type: "session",
      session_id: safe(() => manager.getSessionId()),
      session_file: safe(() => manager.getSessionFile()),
      cwd: safe(() => manager.getCwd()) ?? context?.cwd ?? null,
      model: modelOf(context?.model),
      thinking,
      thinking_levels: thinkingLevels(context?.model),
      idle: safe(() => context.isIdle()) ?? true,
    };
  }

  function models() {
    const scoped = safe(() => context.scopedModels) ?? [];
    const available = scoped.length
      ? scoped.map((entry) => entry.model)
      : safe(() => context.modelRegistry.getAvailable()) ?? [];
    return { type: "models", models: available.map(modelOf).filter(Boolean) };
  }

  function commands() {
    const list = safe(() => pi.getCommands()) ?? [];
    return {
      type: "commands",
      commands: list.map((command) => ({
        name: String(command.name ?? ""),
        description: String(command.description ?? ""),
        source: String(command.source ?? ""),
        scope: String(command.sourceInfo?.scope ?? ""),
      })),
    };
  }

  function usage() {
    const current = safe(() => context.getContextUsage());
    if (!current) return;
    send({ type: "usage", tokens: current.tokens, context_window: current.contextWindow });
  }

  function announce() {
    send(session());
    send(models());
    send(commands());
    usage();
  }

  async function prompt(request) {
    const content = [{ type: "text", text: String(request.text ?? "") }];
    for (const image of request.images ?? []) {
      const data = fs.readFileSync(image.path).toString("base64");
      content.push({ type: "image", data, mimeType: image.media_type || "image/png" });
    }
    const message = content.length === 1 ? content[0].text : content;
    const expandPromptTemplates = content[0].text.startsWith("/");
    if (safe(() => context.isIdle()) ?? true) {
      pi.sendUserMessage(message, { expandPromptTemplates });
      return { delivery: "started" };
    }
    pi.sendUserMessage(message, { deliverAs: "steer", expandPromptTemplates });
    return { delivery: "steered" };
  }

  async function handle(request) {
    switch (request.type) {
      case "prompt":
        return prompt(request);
      case "abort":
        context.abort();
        return {};
      case "set_model": {
        const model = context.modelRegistry.find(request.provider, request.model);
        if (!model) throw new Error(`pi has no model ${request.provider}/${request.model}`);
        if (!(await pi.setModel(model))) throw new Error("pi has no key for this model");
        return {};
      }
      case "set_thinking":
        pi.setThinkingLevel(request.level);
        return {};
      case "state":
        announce();
        return {};
      default:
        throw new Error(`unknown request ${request.type}`);
    }
  }

  function receive(chunk) {
    pending += chunk;
    if (pending.length > LINE_LIMIT) {
      socket.destroy();
      return;
    }
    let newline;
    while ((newline = pending.indexOf("\n")) >= 0) {
      const line = pending.slice(0, newline);
      pending = pending.slice(newline + 1);
      let request;
      try {
        request = JSON.parse(line);
      } catch {
        continue;
      }
      if (request.type === "ready") {
        socket.gudoReady = true;
        retryMs = RETRY_FIRST_MS;
        announce();
        continue;
      }
      Promise.resolve()
        .then(() => handle(request))
        .then(
          (data) => send({ type: "reply", id: request.id, ok: true, data }),
          (error) => send({ type: "reply", id: request.id, ok: false, error: String(error?.message ?? error) }),
        );
    }
  }

  function connect() {
    retryTimer = undefined;
    if (ending || socket) return;
    const path = socketPath();
    if (!path) return;
    const connection = net.createConnection(path);
    socket = connection;
    pending = "";
    connection.setEncoding("utf8");
    connection.on("connect", () => {
      connection.write(
        JSON.stringify({ pi_bridge: { v: PROTOCOL, token, pane, pid: process.pid } }) + "\n",
      );
    });
    connection.on("data", receive);
    connection.on("error", () => {});
    connection.on("close", () => {
      if (socket === connection) socket = undefined;
      if (ending || retryTimer) return;
      retryTimer = setTimeout(connect, retryMs);
      retryTimer.unref?.();
      retryMs = Math.min(retryMs * 2, RETRY_LAST_MS);
    });
    connection.unref?.();
  }

  pi.on("session_start", async (_event, ctx) => {
    context = ctx;
    if (socket) announce();
    else connect();
  });
  pi.on("session_shutdown", async () => {
    ending = true;
    if (retryTimer) clearTimeout(retryTimer);
    socket?.end();
  });
  pi.on("session_info_changed", async () => send(session()));
  pi.on("model_select", async () => {
    send(session());
    usage();
  });
  pi.on("thinking_level_select", async () => send(session()));
  pi.on("agent_start", async () => send({ type: "busy", busy: true }));
  pi.on("agent_settled", async (event) =>
    send({ type: "busy", busy: false, aborted: Boolean(event?.aborted) }),
  );
  pi.on("message_start", async (event) => {
    if (event.message?.role !== "assistant") return;
    send({ type: "message_start", timestamp: event.message.timestamp ?? 0 });
  });
  pi.on("message_update", async (event) => {
    const update = event.assistantMessageEvent;
    if (!update || (update.type !== "text_delta" && update.type !== "thinking_delta")) return;
    send({
      type: "delta",
      timestamp: event.message?.timestamp ?? 0,
      index: update.contentIndex ?? 0,
      kind: update.type === "text_delta" ? "text" : "thinking",
      text: update.delta ?? "",
    });
  });
  pi.on("message_end", async (event) => {
    if (event.message?.role !== "assistant") return;
    send({
      type: "message_end",
      timestamp: event.message.timestamp ?? 0,
      stop_reason: event.message.stopReason ?? null,
    });
    usage();
  });
  pi.on("resources_discover", async () => send(commands()));
};

function safe(read) {
  try {
    return read();
  } catch {
    return undefined;
  }
}

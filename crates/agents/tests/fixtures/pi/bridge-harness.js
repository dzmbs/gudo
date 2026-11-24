// Runs the pi bridge extension against a stand-in pi and a stand-in helper socket.
// Usage: node bridge-harness.js <bridge.js> <socket path>, with the pane variables naming pane
// 7, token "pane-token" and that socket.
const net = require("node:net");
const assert = require("node:assert");

const [bridgePath, socketPath] = process.argv.slice(2);

const handlers = {};
const sent = [];
let aborted = 0;
let thinking = "medium";
const model = { provider: "anthropic", id: "claude-opus-4-5", name: "Opus", reasoning: true };
const pi = {
  on: (event, handler) => (handlers[event] = handler),
  sendUserMessage: (message, options) => sent.push({ message, options }),
  getCommands: () => [{ name: "review", description: "Review", source: "prompt", sourceInfo: { scope: "project" } }],
  getThinkingLevel: () => thinking,
  setThinkingLevel: (level) => (thinking = level),
  setModel: async () => true,
};
let idle = true;
const context = {
  cwd: "/work",
  model,
  scopedModels: [],
  modelRegistry: { getAvailable: () => [model], find: () => model },
  sessionManager: { getSessionId: () => "0199-aaaa", getSessionFile: () => "/s.jsonl", getCwd: () => "/work" },
  isIdle: () => idle,
  abort: () => aborted++,
  getContextUsage: () => ({ tokens: 1200, contextWindow: 200000, percent: 0.6 }),
};

require(bridgePath)(pi);

function lines(socket, onMessage) {
  let pending = "";
  socket.setEncoding("utf8");
  socket.on("data", (chunk) => {
    pending += chunk;
    let newline;
    while ((newline = pending.indexOf("\n")) >= 0) {
      onMessage(JSON.parse(pending.slice(0, newline)));
      pending = pending.slice(newline + 1);
    }
  });
}

const timeout = setTimeout(() => {
  console.error("the bridge did not finish in time");
  process.exit(1);
}, 10000);

let connections = 0;
const server = net.createServer((socket) => {
  connections += 1;
  const connection = connections;
  const received = [];
  const write = (message) => socket.write(JSON.stringify(message) + "\n");
  lines(socket, async (message) => {
    received.push(message);
    if (message.pi_bridge) {
      assert.deepStrictEqual(message.pi_bridge.v, 1);
      assert.strictEqual(message.pi_bridge.token, "pane-token");
      assert.strictEqual(message.pi_bridge.pane, "7");
      write({ type: "ready" });
      return;
    }
    if (connection === 1 && message.type === "commands") {
      const session = received.find((each) => each.type === "session");
      assert.strictEqual(session.session_id, "0199-aaaa");
      assert.strictEqual(session.model.name, "Opus");
      assert.deepStrictEqual(session.thinking_levels.slice(0, 2), ["off", "minimal"]);
      assert.strictEqual(message.commands[0].scope, "project");
      write({ id: 1, type: "prompt", text: "run the tests" });
      return;
    }
    if (connection === 1 && message.type === "reply" && message.id === 1) {
      assert.ok(message.ok);
      assert.strictEqual(sent[0].message, "run the tests");
      idle = false;
      write({ id: 2, type: "prompt", text: "/review" });
      return;
    }
    if (connection === 1 && message.type === "reply" && message.id === 2) {
      assert.strictEqual(sent[1].options.deliverAs, "steer");
      assert.strictEqual(sent[1].options.expandPromptTemplates, true);
      await handlers.message_update({
        message: { role: "assistant", timestamp: 5 },
        assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "Hi" },
      });
      return;
    }
    if (connection === 1 && message.type === "delta") {
      assert.deepStrictEqual(message, { type: "delta", timestamp: 5, index: 0, kind: "text", text: "Hi" });
      socket.destroy();
      return;
    }
    if (connection === 2 && message.type === "commands") {
      write({ id: 3, type: "set_thinking", level: "high" });
      write({ id: 4, type: "abort" });
      return;
    }
    if (connection === 2 && message.type === "reply" && message.id === 4) {
      assert.ok(message.ok);
      assert.strictEqual(thinking, "high");
      assert.strictEqual(aborted, 1);
      await handlers.session_shutdown({ reason: "quit" }, context);
      clearTimeout(timeout);
      server.close();
      console.log("ok");
    }
  });
});
server.listen(socketPath, () => handlers.session_start({ reason: "startup" }, context));

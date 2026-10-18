#!/usr/bin/env node
// A fake APNs for local development (`npm run fake-apns`, with `npm run dev` in another
// terminal). Listens on 127.0.0.1:8790 over HTTP/1.1, checks the request shape the relay
// sends, logs it, and answers like APNs:
//
// - device tokens starting with `dead` → 410 Unregistered (the daemon drops the device);
// - tokens starting with `busy` → 503 (the daemon retries);
// - anything else → 200 with an apns-id.
//
// GET /log returns everything received as JSON (handy for scripts).
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";

const port = Number(process.env.FAKE_APNS_PORT ?? 8790);
const log = [];

createServer((req, res) => {
  if (req.method === "GET" && req.url === "/log") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(log, null, 2));
    return;
  }
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    const token = (req.url ?? "").replace(/^\/3\/device\//, "");
    const problems = [];
    if (!req.url?.startsWith("/3/device/")) problems.push("path is not /3/device/<token>");
    if (!/^bearer [\w-]+\.[\w-]+\.[\w-]+$/.test(req.headers.authorization ?? ""))
      problems.push("no provider JWT");
    for (const h of ["apns-topic", "apns-push-type", "apns-priority"]) {
      if (!req.headers[h]) problems.push(`missing ${h}`);
    }
    let payload;
    try {
      payload = JSON.parse(body);
    } catch {
      problems.push("body is not JSON");
    }
    if (Buffer.byteLength(body) > 4096) problems.push("payload over 4 KiB");
    const entry = {
      at: new Date().toISOString(),
      token,
      headers: {
        topic: req.headers["apns-topic"],
        pushType: req.headers["apns-push-type"],
        priority: req.headers["apns-priority"],
        collapseId: req.headers["apns-collapse-id"],
      },
      payload,
      problems,
    };
    log.push(entry);
    console.log(JSON.stringify(entry, null, 2));
    if (problems.length) {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ reason: "BadRequest", problems }));
    } else if (token.startsWith("dead")) {
      res.writeHead(410, { "content-type": "application/json" });
      res.end(JSON.stringify({ reason: "Unregistered", timestamp: Date.now() }));
    } else if (token.startsWith("busy")) {
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ reason: "ServiceUnavailable" }));
    } else {
      res.writeHead(200, { "apns-id": randomUUID() });
      res.end();
    }
  });
}).listen(port, "127.0.0.1", () => {
  console.log(`fake APNs on http://127.0.0.1:${port} (GET /log for what arrived)`);
});

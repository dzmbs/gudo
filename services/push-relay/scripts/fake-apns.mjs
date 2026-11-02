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

createServer((request, response) => {
  if (request.method === "GET" && request.url === "/log") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(log, null, 2));
    return;
  }
  let body = "";
  request.on("data", (chunk) => (body += chunk));
  request.on("end", () => {
    const token = (request.url ?? "").replace(/^\/3\/device\//, "");
    const problems = [];
    if (!request.url?.startsWith("/3/device/")) problems.push("path is not /3/device/<token>");
    if (!/^bearer [\w-]+\.[\w-]+\.[\w-]+$/.test(request.headers.authorization ?? ""))
      problems.push("no provider JWT");
    for (const header of ["apns-topic", "apns-push-type", "apns-priority"]) {
      if (!request.headers[header]) problems.push(`missing ${header}`);
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
        topic: request.headers["apns-topic"],
        pushType: request.headers["apns-push-type"],
        priority: request.headers["apns-priority"],
        collapseId: request.headers["apns-collapse-id"],
      },
      payload,
      problems,
    };
    log.push(entry);
    console.log(JSON.stringify(entry, null, 2));
    if (problems.length) {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ reason: "BadRequest", problems }));
    } else if (token.startsWith("dead")) {
      response.writeHead(410, { "content-type": "application/json" });
      response.end(JSON.stringify({ reason: "Unregistered", timestamp: Date.now() }));
    } else if (token.startsWith("busy")) {
      response.writeHead(503, { "content-type": "application/json" });
      response.end(JSON.stringify({ reason: "ServiceUnavailable" }));
    } else {
      response.writeHead(200, { "apns-id": randomUUID() });
      response.end();
    }
  });
}).listen(port, "127.0.0.1", () => {
  console.log(`fake APNs on http://127.0.0.1:${port} (GET /log for what arrived)`);
});

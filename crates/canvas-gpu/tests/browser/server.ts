// Static qualification server. Run through Devbox from the repository root.
import { join } from "node:path";

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port <= 0) throw new Error("pass the Devbox port");
const root = process.cwd();
Bun.serve({
  hostname: process.env.BIND_HOST ?? "0.0.0.0",
  port,
  async fetch(request) {
    const url = new URL(request.url);
    const paths: Record<string, string> = {
      "/": "crates/canvas-gpu/tests/browser/index.html",
      "/golden.json": "crates/canvas-gpu/tests/browser/golden.json",
      "/browser.js": "target/browser/browser.js",
      "/browser_bg.wasm": "target/browser/browser_bg.wasm",
    };
    if (url.pathname === "/capture" && request.method === "POST") {
      // A baseline candidate stays in ignored build output until reviewed on the Mac.
      await Bun.write(join(root, "target/browser/candidate.json"), await request.text());
      return new Response("saved");
    }
    const path = paths[url.pathname];
    if (!path) return new Response("not found", { status: 404 });
    const file = Bun.file(join(root, path));
    if (!(await file.exists())) return new Response("not built", { status: 404 });
    return new Response(file, { headers: { "Cache-Control": "no-store" } });
  },
});
console.log(`renderer qualification listening on ${port}`);

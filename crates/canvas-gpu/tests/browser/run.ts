// CI entrypoint: drive the already-running Devbox page with headless Chromium.
// Uses Chromium's built-in DOM runner, so no package installation is required.
const url = process.argv[2];
const executable = process.env.CHROMIUM_PATH;
if (!url || !executable) throw new Error("pass the qualification URL and CHROMIUM_PATH");
const profile = await import("node:fs/promises").then(fs => fs.mkdtemp(`${process.env.TMPDIR ?? "/tmp"}/canvas-browser-`));
const child = Bun.spawn([
  executable,
  "--headless",
  "--use-gl=angle",
  "--use-angle=swiftshader",
  "--enable-unsafe-swiftshader",
  "--disable-webgpu",
  "--dump-dom",
  "--virtual-time-budget=60000",
  "--timeout=120000",
  `--user-data-dir=${profile}`,
  url,
], { stdout: "pipe", stderr: "pipe" });
const [html, diagnostics, exit] = await Promise.all([
  new Response(child.stdout).text(),
  new Response(child.stderr).text(),
  child.exited,
]);
const raw = html.match(/<pre id="result">([\s\S]*?)<\/pre>/)?.[1];
if (!raw) throw new Error(`Chromium returned no result (exit ${exit}): ${diagnostics}`);
const report = JSON.parse(raw.replaceAll("&quot;", '"').replaceAll("&amp;", "&"));
console.log(JSON.stringify({ ...report, chromiumExit: exit }, null, 2));
if (exit !== 0 || !report.passed) process.exitCode = 1;

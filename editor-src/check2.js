const { JSDOM, VirtualConsole } = require("jsdom");
const fs = require("fs");
const js = fs.readFileSync("editor-all.js", "utf8");

const html = `<!doctype html><html><body><div id="editor"></div>
<script>${js.replace(/<\/script/g, "<\\/script")}</script></body></html>`;

const errors = [];
const vc = new VirtualConsole();
vc.on("jsdomError", (e) => errors.push("jsdomError: " + (e.message || e)));
vc.on("error", (m) => errors.push("console.error: " + String(m).slice(0,160)));

const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true, virtualConsole: vc });
const w = dom.window;
console.log("toastui:", typeof w.toastui);
console.log("toastui.Editor:", w.toastui && typeof w.toastui.Editor);
console.log("errors:", errors.length);
errors.slice(0, 3).forEach((e) => console.log("  -", e.slice(0, 160)));

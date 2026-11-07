const { JSDOM } = require("jsdom");
const fs = require("fs");
const path = require("path");

const html = fs.readFileSync(path.join(__dirname, "../Sources/ClipNote2/Resources/editor-bundle.html"), "utf8");

const errors = [];
const vc = new (require("jsdom").VirtualConsole)();
vc.on("jsdomError", (e) => errors.push("jsdomError: " + (e.message || e)));
vc.on("error", (m) => errors.push("console.error: " + m));

const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true, virtualConsole: vc });
const w = dom.window;

console.log("toastui:", typeof w.toastui);
console.log("toastui.Editor:", w.toastui && typeof w.toastui.Editor);
console.log("ready flag:", w.__ready);
console.log("errors:", errors.length);
errors.slice(0, 4).forEach((e) => console.log("  -", e.slice(0, 200)));

// 自研编辑器的冒烟自检：先在 jsdom 里跑，回答「有没有起来」。
// 布局类问题（能不能横滑、渐隐在不在）jsdom 一律返回 0，交给真实浏览器那张图。
const { JSDOM, VirtualConsole } = require("jsdom");
const fs = require("fs");
const path = require("path");

const file = path.join(__dirname, "../Sources/ClipNote2/Resources/editor-bundle.html");
const html = fs.readFileSync(file, "utf8");

const errors = [];
const posted = [];
const vc = new VirtualConsole();
vc.on("jsdomError", (e) => errors.push(String(e.message || e).slice(0, 300)));
vc.on("error", (m) => errors.push("console.error: " + String(m).slice(0, 300)));

const dom = new JSDOM(html, {
  runScripts: "dangerously",
  pretendToBeVisual: true,
  virtualConsole: vc,
  url: "file:///tmp/editor.html",
  beforeParse(window) {
    window.webkit = { messageHandlers: { editor: { postMessage: (p) => posted.push(p) } } };

    // jsdom 没有布局，也就没有 getClientRects。ProseMirror 在 scrollIntoView 时
    // 会调它（撤销、插入都会走到），不补就会抛 "e.getClientRects is not a function"，
    // 被 window.onerror 当成致命错误——那是脚手架缺口，不是编辑器的问题。
    const emptyRect = () => ({
      x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0,
    });
    window.Element.prototype.getClientRects = function () { return [emptyRect()]; };
    window.Range.prototype.getClientRects = function () { return [emptyRect()]; };
    if (!window.Range.prototype.getBoundingClientRect) {
      window.Range.prototype.getBoundingClientRect = emptyRect;
    }
  },
});

const failures = [];
function ok(cond, label, detail) {
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${detail === undefined ? "" : "  →  " + detail}`);
  if (!cond) failures.push(label);
}

setTimeout(() => {
  const w = dom.window;
  const d = w.document;
  const probe = typeof w.__probe === "function" ? w.__probe() : null;

  console.log("── 启动 ──");
  ok(errors.length === 0, "运行期零报错", errors.slice(0, 2).join(" | ") || "0 条");
  ok(posted.some((p) => p.type === "ready"), "已向原生端发出 ready");
  ok(probe && probe.ok, "__probe 可用");

  console.log("── 结构 ──");
  ok(!!d.querySelector(".cn-tb"), "工具栏已挂载");
  ok(!!d.querySelector(".ProseMirror"), "编辑区已挂载");
  ok((probe && probe.items) === 19, "工具栏 19 个按钮", probe ? `${probe.items} 个` : "-");
  ok(!!d.querySelector(".cn-tb-fade"), "右缘渐隐层存在");
  ok(d.querySelectorAll(".cn-tb-divider").length === 5, "5 条分隔线",
    `${d.querySelectorAll(".cn-tb-divider").length} 条`);

  console.log("── 工具栏行为 ──");
  const codeBtn = d.querySelector('.cn-tb-btn[data-cmd="codeblock"]');
  ok(!!codeBtn, "代码块按钮存在");
  if (codeBtn) {
    codeBtn.click();
    const inCode = w.__getMarkdown();
    ok(inCode.startsWith("```"), "点一次进入代码块", JSON.stringify(inCode.slice(0, 8)));
    codeBtn.click();
    const backToText = w.__getMarkdown();
    ok(!backToText.includes("```"), "再点一次退回正文——手机上没有 Esc，必须有退路");
  }

  const undoBtn = d.querySelector('.cn-tb-btn[data-cmd="undo"]');
  const redoBtn = d.querySelector('.cn-tb-btn[data-cmd="redo"]');
  ok(!!undoBtn && !!redoBtn, "撤销 / 重做按钮存在");
  if (undoBtn && redoBtn) {
    w.__replaceAll("第一版内容");
    ok(!undoBtn.disabled, "有变更后撤销可点");
    undoBtn.click();
    ok(w.__getMarkdown() === "", "撤销回到变更前");
    ok(!redoBtn.disabled, "撤销后重做可点");
    redoBtn.click();
    ok(w.__getMarkdown() === "第一版内容", "重做恢复内容");
    w.__replaceAll("");
  }

  console.log("── 粘贴 ──");
  {
    const pmDom = d.querySelector(".ProseMirror");
    w.__replaceAll("");
    const ev = new w.Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(ev, "clipboardData", {
      value: {
        types: ["text/plain"],
        getData: (kind) => (kind === "text/plain" ? "<ol><li>甲</li><li>乙</li></ol>" : ""),
      },
    });
    pmDom.dispatchEvent(ev);
    const pasted = w.__getMarkdown();
    ok(pasted.includes("甲"), "纯文本里的 HTML 片段被当成结构插入", JSON.stringify(pasted));
    ok(!pasted.includes("<ol>"), "正文里不出现 <ol> 标签");
  }

  console.log("── 内容 ──");
  const initial = w.__getMarkdown ? w.__getMarkdown() : null;
  ok(typeof initial === "string", "__getMarkdown 可用", initial && initial.slice(0, 30));

  const sample = "# 标题\n\n一段正文，含 **粗体**。\n\n- 甲\n- 乙\n\n> 引用\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n```js\nconst x = 1\n```";
  if (w.__replaceAll) w.__replaceAll(sample);
  const back = w.__getMarkdown ? w.__getMarkdown() : "";
  ok(back.includes("# 标题"), "一级标题往返保留");
  ok(back.includes("**粗体**"), "粗体往返保留");
  ok(back.includes("- 甲"), "无序列表往返保留");
  ok(back.includes("> 引用"), "引用往返保留");
  ok(back.includes("| a | b |"), "表格往返保留", back.split("\n").find((l) => l.startsWith("|")) || "无");
  ok(back.includes("```js"), "代码块语言保留");

  // 图片：往返要逐字一致；插入接口只认 http(s)
  const imgMd = "看图：![截图](https://example.com/a.png) 就是这样";
  w.__replaceAll(imgMd);
  ok(w.__getMarkdown() === imgMd, "图片 Markdown 逐字往返", JSON.stringify(w.__getMarkdown()));
  w.__replaceAll("");
  ok(w.__insertImage("data:image/png;base64,AAA") === false, "拒绝 data: 地址（会把笔记撑爆）");
  ok(w.__insertImage("https://example.com/b.png") === true, "插入 https 图片");
  ok(w.__getMarkdown() === "![](https://example.com/b.png)", "插入结果写入正文");

  // 高亮与删除线：这两个以前不在序列化器的标记表里，
  // 一带上就会在保存时抛错，而平时完全看不出来。
  for (const sample of [
    "这是 ==高亮== 的一句",
    "这句 ~~划掉~~ 了",
    "混合 ==高亮 **粗体**==",
    "绿色 =={g}绿色高亮==",
    "蓝色 =={b}蓝色== 与 粉色 =={p}粉色==",
    "橙色 =={o}橙色== 紫色 =={u}紫色==",
    "跨格式 =={g}高亮 **粗体** 并列== 结束",
    "落单的 == 不是高亮",
  ]) {
    w.__replaceAll(sample);
    ok(w.__getMarkdown() === sample, "逐字往返：" + sample, JSON.stringify(w.__getMarkdown()));
  }

  // 调色板：点开高亮按钮，应出现 6 个色块 + 「取消高亮」
  const hlBtn = d.querySelector('.cn-tb-btn[data-cmd="highlight"]');
  ok(!!hlBtn, "高亮按钮存在");
  if (hlBtn) {
    hlBtn.click();
    ok(d.querySelectorAll(".cn-tb-swatch").length === 6, "调色板 6 个色块",
      String(d.querySelectorAll(".cn-tb-swatch").length));
    const clearBtn = [...d.querySelectorAll(".cn-tb-item")].find((n) => n.textContent === "取消高亮");
    ok(!!clearBtn, "调色板带「取消高亮」");
    hlBtn.click(); // 再点一次关掉，别影响后续用例
  }

  const tasks = "- [ ] 还没做\n- [x] 已经做完";
  w.__replaceAll(tasks);
  const taskBack = w.__getMarkdown();
  ok(taskBack.includes("- [ ] 还没做"), "未勾选任务往返保留", taskBack.split("\n")[0]);
  ok(taskBack.includes("- [x] 已经做完"), "已勾选任务往返保留");

  // 普通项和任务项写在同一个列表里，是笔记里最常见的形态。
  // 用逐字相等断言：这里一旦变形（比如 ul 被当成 ol），只有精确比较才抓得住。
  const mixed = "- 普通一\n- 普通二\n- [ ] 任务一\n- [x] 任务二";
  w.__replaceAll(mixed);
  const mixedBack = w.__getMarkdown();
  ok(mixedBack === mixed, "混排列表逐字往返", JSON.stringify(mixedBack));

  setTimeout(() => {
    const changed = posted.filter((p) => p.type === "change");
    ok(changed.length > 0, "内容变化回传 change", `${changed.length} 次`);
    const errs = posted.filter((p) => p.type === "error");
    ok(errs.length === 0, "没有向原生端报 error", errs.map((e) => e.message).join(" | ") || "0 条");

    console.log("");
    if (failures.length) {
      console.log(`结果：${failures.length} 项未通过 —— ${failures.join(" / ")}`);
      process.exit(1);
    }
    console.log("结果：全部通过");
    process.exit(0);
  }, 700);
}, 1500);

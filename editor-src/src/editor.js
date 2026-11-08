// 编辑器装配与原生端桥接。
//
// 桥协议与旧版完全一致（ready / change / error / trace + __INITIAL_MARKDOWN__），
// 所以 Swift 侧不需要跟着改——换的是引擎，不是接口。
import { EditorState, Plugin } from "prosemirror-state";
import { EditorView } from "prosemirror-view";
import { keymap } from "prosemirror-keymap";
import { baseKeymap, exitCode } from "prosemirror-commands";
import { history, undo, redo } from "prosemirror-history";
import { dropCursor } from "prosemirror-dropcursor";
import { gapCursor } from "prosemirror-gapcursor";
import { tableEditing } from "prosemirror-tables";
import { sinkListItem, liftListItem } from "prosemirror-schema-list";
import { schema, nodes } from "./schema.js";
import { markdownToDoc, docToMarkdown, sliceToMarkdown } from "./markdown.js";
import { markdownInputRules, bold, italic, exitEmptyCodeBlock } from "./commands.js";
import { createToolbar } from "./toolbar.js";
import "./styles.css";

const PLACEHOLDER = "写点什么：这条视频对你有什么用、哪句话值得记、下次要试什么。";

/// 页面标识。改动 DOM 结构或节点模型时改这里的版本号，
/// 这样线上日志能直接看出「装的是哪一版页面」。
const EDITOR_ID = "cn-editor/3";

function post(payload) {
  try {
    window.webkit.messageHandlers.editor.postMessage(payload);
  } catch (e) {
    /* 没有桥（本地浏览器预览）时静默——这不是错误 */
  }
}

/// 空文档时给编辑区挂标记，由 CSS 画占位文字。
/// 不把占位文字塞进文档：那不是内容，不该被复制，也不该被 getMarkdown 拿到。
function placeholderPlugin() {
  return new Plugin({
    view(editorView) {
      const sync = () => {
        const doc = editorView.state.doc;
        const empty = doc.childCount === 1 && doc.firstChild.textContent.trim() === "";
        editorView.dom.classList.toggle("is-empty", empty);
      };
      sync();
      return { update: sync };
    },
  });
}

function buildState(markdown) {
  return EditorState.create({
    doc: markdownToDoc(markdown),
    plugins: [
      history(),
      markdownInputRules,
      keymap({
        "Mod-z": undo,
        "Shift-Mod-z": redo,
        "Mod-y": redo,
        "Mod-b": bold,
        "Mod-i": italic,
        // 放在 baseKeymap 之前：只有在空代码块里才拦截回车，其余情况交回默认行为。
        Enter: exitEmptyCodeBlock,
        Tab: sinkListItem(nodes.list_item),
        "Shift-Tab": liftListItem(nodes.list_item),
        "Mod-Enter": exitCode,
      }),
      keymap(baseKeymap),
      dropCursor(),
      gapCursor(),
      tableEditing(),
      placeholderPlugin(),
    ],
  });
}

export function mount(root) {
  const editorHost = document.createElement("div");
  editorHost.className = "cn-editor";
  root.appendChild(editorHost);

  let toolbar = null;
  let lastSent = "";
  let timer = null;

  const view = new EditorView(editorHost, {
    state: buildState(window.__INITIAL_MARKDOWN__ || ""),
    attributes: { "data-placeholder": PLACEHOLDER, spellcheck: "false" },
    dispatchTransaction(tr) {
      const next = view.state.apply(tr);
      view.updateState(next);
      if (toolbar) toolbar.sync(next);
      scheduleChange(next);
    },
  });

  toolbar = createToolbar(view);
  root.appendChild(toolbar.el);
  toolbar.sync(view.state);

  function currentMarkdown() {
    return docToMarkdown(view.state.doc);
  }

  function scheduleChange(state) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      const value = docToMarkdown(state.doc);
      if (value === lastSent) return;
      lastSent = value;
      post({ type: "change", value });
    }, 350);
  }

  lastSent = currentMarkdown();

  // 页面自报身份与内容规模。
  // 有了这一行，日志里就能一眼分出「跑的是哪个页面」和「内容到底解析成什么」——
  // 上一次的教训：探针只报实现细节，日志里完全看不出页面版本，白查半天。
  const doc = view.state.doc;
  let blocks = 0;
  doc.forEach(() => { blocks += 1; });
  post({
    type: "trace",
    message: `页面 ${EDITOR_ID} · ${blocks} 个块 · ${doc.textContent.length} 字`,
  });

  // 勾选框要能点。只响应左侧 28px 的勾选区域，
  // 点正文仍然是把光标放进这一项——编辑和勾选不该抢同一个手势。
  view.dom.addEventListener("click", (event) => {
    const li = event.target && event.target.closest ? event.target.closest("li[data-task]") : null;
    if (!li) return;
    const rect = li.getBoundingClientRect();
    if (event.clientX - rect.left > 28) return;
    const inside = view.posAtDOM(li, 0);
    for (const candidate of [inside - 1, inside]) {
      const node = view.state.doc.nodeAt(candidate);
      // 只认「带勾选态的列表项」。普通条目的左侧圆点不该被点成任务。
      if (node && node.type === nodes.list_item && node.attrs.checked != null) {
        event.preventDefault();
        view.dispatch(view.state.tr.setNodeMarkup(candidate, null, {
          checked: !node.attrs.checked,
        }));
        return;
      }
    }
  });

  // ── 给原生端的接口 ────────────────────────────────────────────
  window.__getMarkdown = currentMarkdown;

  /// 整体替换。走事务而不是重建 view，所以按一次撤销能回到替换前。
  window.__setMarkdown = (md) => {
    const next = markdownToDoc(md || "");
    const tr = view.state.tr;
    tr.replaceWith(0, view.state.doc.content.size, next.content);
    view.dispatch(tr);
  };

  /// 取选区的 Markdown。没选中返回空串——「全文还是选区」由原生端决定。
  window.__getSelection = () => {
    const { from, to, empty } = view.state.selection;
    if (empty) return "";
    return sliceToMarkdown(view.state.doc, from, to);
  };

  window.__replaceAll = (md) => {
    const next = markdownToDoc(md || "");
    const tr = view.state.tr;
    tr.replaceWith(0, view.state.doc.content.size, next.content);
    view.dispatch(tr);
    return true;
  };

  /// 替换选区。没有选区时返回 false，让原生端明确知道没写成，而不是静默丢弃。
  window.__replaceSelection = (md) => {
    const { from, to, empty } = view.state.selection;
    if (empty) return false;
    view.dispatch(view.state.tr.insertText(md || "", from, to));
    return true;
  };

  window.__focus = () => view.focus();

  window.__probe = () => {
    const tb = document.querySelector(".cn-tb");
    if (!tb) return { ok: false };
    return {
      ok: true,
      mode: "wysiwyg",
      items: tb.querySelectorAll(".cn-tb-btn").length,
      tabVisible: false,
      toolbarScrollWidth: tb.scrollWidth,
      toolbarWidth: Math.round(tb.getBoundingClientRect().width),
      fadeVisible: !!document.querySelector(".cn-tb-fade.on"),
      isEmpty: view.state.doc.textContent.trim() === "",
      chars: view.state.doc.textContent.length,
    };
  };

  post({ type: "ready" });
  return view;
}

window.addEventListener("error", (event) => {
  post({ type: "error", message: `${event.message} @${event.filename}:${event.lineno}` });
});

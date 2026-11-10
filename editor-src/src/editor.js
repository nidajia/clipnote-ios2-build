// 编辑器装配与原生端桥接。
//
// 桥协议与旧版完全一致（ready / change / error / trace + __INITIAL_MARKDOWN__），
// 所以 Swift 侧不需要跟着改——换的是引擎，不是接口。
import { EditorState, Plugin, TextSelection } from "prosemirror-state";
import { Slice } from "prosemirror-model";
import { EditorView } from "prosemirror-view";
import { keymap } from "prosemirror-keymap";
import { baseKeymap, exitCode } from "prosemirror-commands";
import { history, undo, redo } from "prosemirror-history";
import { dropCursor } from "prosemirror-dropcursor";
import { gapCursor } from "prosemirror-gapcursor";
import { tableEditing } from "prosemirror-tables";
import { sinkListItem, liftListItem } from "prosemirror-schema-list";
import { schema, nodes } from "./schema.js";
import { markdownToDoc, docToMarkdown, sliceToMarkdown, looksLikeHtml, htmlToSlice } from "./markdown.js";
import { markdownInputRules, bold, italic, exitEmptyCodeBlock } from "./commands.js";
import { createToolbar } from "./toolbar.js";
import "./styles.css";

const PLACEHOLDER = "写点什么：这条视频对你有什么用、哪句话值得记、下次要试什么。";

/// 页面标识。改动 DOM 结构或节点模型时改这里的版本号，
/// 这样线上日志能直接看出「装的是哪一版页面」。
const EDITOR_ID = "cn-editor/5";

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
        // 「空」必须是「一个空段落」，不能是「一个没有文字的块」。
        // 后者会把空表格、空代码块、分隔线都判成空，占位文字压在内容上。
        const empty = doc.childCount === 1
          && doc.firstChild.type === nodes.paragraph
          && doc.firstChild.content.size === 0;
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

  /// 最后一次非空选区。
  ///
  /// 为什么需要它：AI 的动作条在原生一侧，点它会让 WebView 失焦，
  /// 而失焦时 ProseMirror 的选区可能被清空。清空之后 `__scope()` 只能
  /// 返回空串，原生端就判定成「整篇」——这就是「选了一段却全改了」的成因。
  /// 记住当时那一段，等原生端来问时还回去。
  let savedScope = null;

  function rememberScope(state) {
    const { from, to, empty } = state.selection;
    if (empty || to <= from) return;
    const text = sliceToMarkdown(state.doc, from, to);
    if (!text.trim()) return;
    savedScope = { from, to, text };
  }

  const view = new EditorView(editorHost, {
    state: buildState(window.__INITIAL_MARKDOWN__ || ""),
    attributes: { "data-placeholder": PLACEHOLDER, spellcheck: "false" },
    /// 剪贴板里只有纯文本、而那文本是 HTML 源码时，转成节点再插入。
    /// 不这么做，正文里会永久留下 `<ol><li></ol>` 这种字符串并跟着笔记存进服务端。
    /// 有 text/html 时交给 ProseMirror 默认解析——它比这里更懂结构。
    handlePaste(pasteView, event) {
      const data = event.clipboardData;
      if (!data) return false;
      if ((data.getData("text/html") || "").trim()) return false;
      const text = data.getData("text/plain") || "";
      if (!looksLikeHtml(text)) return false;
      try {
        const slice = htmlToSlice(text);
        if (!slice.size) return false;
        pasteView.dispatch(pasteView.state.tr.replaceSelection(slice).scrollIntoView());
        return true;
      } catch (error) {
        // 结构装不下（比如往表格格里塞整张表）就退回默认粘贴，
        // 宁可留下文字，也不能吞掉用户复制的东西。
        return false;
      }
    },
    dispatchTransaction(tr) {
      const next = view.state.apply(tr);
      view.updateState(next);
      rememberScope(next);
      if (toolbar) toolbar.sync(next);
      scheduleChange(next);
    },
  });

  toolbar = createToolbar(view, {
    // 选图必须由原生端做：WebView 里的 <input type=file> 在 iOS 上
    // 依赖未文档化的行为，而且上传要绕 CORS。交给 PHPicker + URLSession 更确定。
    pickImage: () => post({ type: "pickImage" }),
  });
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
  /// 保留这个旧接口是因为别的路径（粘贴、工具栏）还在用它。
  window.__getSelection = () => {
    const { from, to, empty } = view.state.selection;
    if (empty) return "";
    return sliceToMarkdown(view.state.doc, from, to);
  };

  /// 取「这次要处理的范围」，带位置。
  ///
  /// 返回 `{ text, from, to, kind }`：
  /// - `kind: "live"`  当前就有选区
  /// - `kind: "saved"` 焦点已离开编辑器，用的是最后一次记住的选区
  /// - `kind: "doc"`   确实没有选区，处理整篇
  ///
  /// 原生端必须按 `kind` 决定作用域，不能再靠「text 是不是空」猜——
  /// 之前正是靠猜，才会有「选了一段却改全篇」。
  window.__scope = () => {
    const state = view.state;
    const { from, to, empty } = state.selection;
    if (!empty && to > from) {
      const text = sliceToMarkdown(state.doc, from, to);
      if (text.trim()) {
        savedScope = { from, to, text };
        return { text, from, to, kind: "live" };
      }
    }
    if (!view.hasFocus() && savedScope && savedScope.to <= state.doc.content.size) {
      const now = sliceToMarkdown(state.doc, savedScope.from, savedScope.to);
      // 位置上的文字必须还是当初那段，否则这个位置已经被别人占了
      if (now === savedScope.text) {
        return { text: now, from: savedScope.from, to: savedScope.to, kind: "saved" };
      }
    }
    return { text: "", from: 0, to: 0, kind: "doc" };
  };

  window.__clearScope = () => {
    savedScope = null;
    return true;
  };

  /// 选中某个位置区间。给原生端与自检用：
  /// 自检要在没有真实触摸的情况下复现「选了一段」这个前提。
  window.__selectRange = (from, to) => {
    const max = view.state.doc.content.size;
    const a = Math.max(0, Math.min(Math.round(Number(from) || 0), max));
    const b = Math.max(a, Math.min(Math.round(Number(to) || 0), max));
    try {
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, a, b)));
      return true;
    } catch (error) {
      return false;
    }
  };

  /// 把一段 Markdown 写回指定位置。
  ///
  /// 两件事都要做对，缺一个就会出问题：
  /// 1. **按位置写**，不按「当前选区」写——生成到采用之间用户可能点过正文，
  ///    当前选区已经不是当初那段了；
  /// 2. **解析成节点再写**，不能用 insertText 当纯文本插进去。
  ///    后者会把 `## 标题` 变成正文里的字面井号（这个 bug 之前一直在）。
  window.__applyScope = (md, from, to, expect) => {
    const state = view.state;
    if (typeof from !== "number" || typeof to !== "number" || to <= from) {
      return { ok: false, reason: "no_range" };
    }
    if (to > state.doc.content.size) {
      return { ok: false, reason: "range_changed" };
    }
    if (sliceToMarkdown(state.doc, from, to) !== expect) {
      return { ok: false, reason: "range_changed" };
    }
    let singleBlock = false;
    try {
      singleBlock = state.doc.resolve(from).parent === state.doc.resolve(to).parent;
    } catch (error) {
      singleBlock = false;
    }
    let slice;
    try {
      const parsed = markdownToDoc(md || "");
      slice = new Slice(parsed.content, 0, 0);
      // 只有一段、而且选区没跨块时，按**行内**内容插入。
      // 否则「把一句里的三个字换成另一句」会把原段落切成两段——
      // 用户看到的是句子被拆开，而不是替换了三个字。
      if (slice.content.childCount === 1 && singleBlock) {
        const only = slice.content.firstChild;
        if (only && only.type === nodes.paragraph) {
          slice = new Slice(only.content, 0, 0);
        }
      }
    } catch (error) {
      return { ok: false, reason: "parse_failed" };
    }
    // 块级内容（标题、列表、表格）要插进段落时，先把范围对齐到块边界。
    //
    // 不对齐的话，ProseMirror 会把原段落切开、留下一个空段落：
    // 用户在正文里看到「莫名多了一个空行」，它还会一路存进 Markdown。
    // 只在「选区本来就贴着块的首尾」时才扩，所以不会多吃掉一个字。
    let start = from;
    let end = to;
    const first = slice.content.firstChild;
    if (first && !first.isInline) {
      try {
        const $from = state.doc.resolve(from);
        if ($from.parent.isTextblock && $from.parentOffset === 0 && $from.depth > 0) {
          start = $from.before();
        }
        const $to = state.doc.resolve(to);
        if ($to.parent.isTextblock
            && $to.parentOffset === $to.parent.content.size
            && $to.depth > 0) {
          end = $to.after();
        }
      } catch (error) {
        start = from;
        end = to;
      }
    }
    try {
      view.dispatch(state.tr.replace(start, end, slice).scrollIntoView());
    } catch (error) {
      return { ok: false, reason: "apply_failed" };
    }
    return { ok: true, reason: "" };
  };

  /// 删掉紧贴插入点两侧的空段落。
  ///
  /// 把一段块级内容（比如 `## 标题`）插进段落中间时，ProseMirror 会把原段落
  /// 一分为二，剩下的那半截如果本来就是空的，就会多出一个空行。
  /// 用户在正文里看到的是「莫名多了个空行」，而它会被一路存进 Markdown。


  /// 光标放到文末。新建笔记时用：模板已经铺好，用户从最后一行接着写。
  window.__focusEnd = () => {
    const size = view.state.doc.content.size;
    try {
      const tr = view.state.tr.setSelection(
        TextSelection.near(view.state.doc.resolve(Math.max(0, size - 1)), -1)
      );
      view.dispatch(tr);
    } catch (error) {
      /* 空文档也可能解析失败，忽略即可：光标本来就是唯一的落点 */
    }
    view.focus();
    return true;
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

  /// 插入图片。由原生端在「选图 → 上传」成功后调用。
  /// 只认 http(s)：把 data: 或 file: 塞进来会让笔记变成几百 KB 的字符串，
  /// 而笔记字段服务端只留 4000 字。
  window.__insertImage = (url, alt) => {
    const source = String(url || "").trim();
    if (!/^https?:\/\//i.test(source)) return false;
    try {
      const node = nodes.image.create({ src: source, alt: alt || null });
      view.dispatch(view.state.tr.replaceSelectionWith(node).scrollIntoView());
      return true;
    } catch (error) {
      return false;
    }
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

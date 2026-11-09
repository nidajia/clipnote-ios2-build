// Markdown ↔ 文档。
//
// 解析走一条看起来绕、但最不容易丢东西的路：
//   Markdown --markdown-it--> HTML --prosemirror DOMParser--> 文档
// 而不是自己写 token→节点映射。理由：表格、嵌套列表、代码块里的语言标记
// 这些边界情况，markdown-it 已经处理过千万次；自己映射等于把它们全赌一遍。
//
// 序列化反过来必须自己写：产出的是用户笔记的**存储格式**，
// 必须逐字可控，不能受库的默认风格左右。
import markdownit from "markdown-it";
import { DOMParser as PMDOMParser, Slice } from "prosemirror-model";
import {
  MarkdownSerializer,
  MarkdownSerializerState,
  defaultMarkdownSerializer,
} from "prosemirror-markdown";
import { schema } from "./schema.js";

// html:false —— 笔记里不该有内联 HTML，关掉可以让粘贴内容走纯文本路径，
// 也避免把外部 HTML 原样塞进编辑区。
const md = markdownit("default", {
  html: false,
  linkify: false,
  breaks: false,
  typographer: false,
});

// 高亮：`==这段==`（黄）或 `=={g}这段==`（绿）→ <mark data-c="g">。
//
// 不用 markdown-it-mark 的原因：它只认 `==`，没有颜色位。
// 这里改成「inline 解析完之后扫一遍 text token」——
// `**粗体**` 之类已经成型，包在中间的自然跟着被标记包住，嵌套不用另外处理。
const DELIM = /==(?:\{([a-z])\})?/g;

function applyHighlight(tokens, Token) {
  const hits = [];
  tokens.forEach((tok, index) => {
    if (tok.type !== "text") return;
    DELIM.lastIndex = 0;
    let match;
    while ((match = DELIM.exec(tok.content)) !== null) {
      hits.push({
        tokenIndex: index,
        at: match.index,
        len: match[0].length,
        color: match[1] || "y",
      });
    }
  });
  if (hits.length < 2) return tokens;

  // 两两配对：第 1 个开、第 2 个合……落单的最后一个不处理，原样留作文字
  const usable = hits.slice(0, hits.length - (hits.length % 2));
  const byToken = new Map();
  usable.forEach((hit, i) => {
    hit.open = i % 2 === 0;
    if (!byToken.has(hit.tokenIndex)) byToken.set(hit.tokenIndex, []);
    byToken.get(hit.tokenIndex).push(hit);
  });

  const makeText = (content) => {
    const token = new Token("text", "", 0);
    token.content = content;
    return token;
  };
  const makeMark = (open, color) => {
    if (open) {
      const token = new Token("cn_highlight_open", "mark", 1);
      token.meta = { color };
      return token;
    }
    return new Token("cn_highlight_close", "mark", -1);
  };

  const out = [];
  tokens.forEach((tok, index) => {
    const list = byToken.get(index);
    if (!list) {
      out.push(tok);
      return;
    }
    const content = tok.content;
    let cursor = 0;
    list.forEach((hit) => {
      if (hit.at > cursor) out.push(makeText(content.slice(cursor, hit.at)));
      out.push(makeMark(hit.open, hit.color));
      cursor = hit.at + hit.len;
    });
    if (cursor < content.length) out.push(makeText(content.slice(cursor)));
  });
  return out;
}

md.core.ruler.after("inline", "cn_highlight", (state) => {
  state.tokens.forEach((block) => {
    if (block.type !== "inline" || !block.children) return;
    block.children = applyHighlight(block.children, state.Token);
  });
});

md.renderer.rules.cn_highlight_open = (tokens, idx) => {
  const color = (tokens[idx].meta && tokens[idx].meta.color) || "y";
  return `<mark data-c="${color}">`;
};
md.renderer.rules.cn_highlight_close = () => "</mark>";

/// 单元格内容压成一行：表格在 Markdown 里没有换行位。
function cellText(state, cell) {
  // 用临时 state 渲染，避免污染主缓冲区（state.out 是主缓冲区）。
  const sub = new MarkdownSerializerState(state.nodes, state.marks, state.options);
  cell.forEach((child) => {
    if (child.isTextblock) sub.renderInline(child);
  });
  return sub.out.replace(/\s*\n+\s*/g, " ").trim();
}

function escapeCell(text) {
  return text.replace(/(^|[^\\])\|/g, "$1\\|");
}

/// 表格序列化成 GFM 管道表。
/// 第一行是表头，第二行必须是分隔行 `| --- |`，否则多数解析器不认。
function serializeTable(state, node) {
  const rows = [];
  node.forEach((row) => {
    const cells = [];
    row.forEach((cell) => cells.push(escapeCell(cellText(state, cell))));
    rows.push(cells);
  });
  if (!rows.length) return;

  const cols = Math.max(...rows.map((r) => r.length));
  const pad = (cells) => {
    const copy = cells.slice();
    while (copy.length < cols) copy.push("");
    return copy;
  };
  const line = (cells) => "| " + pad(cells).join(" | ") + " |";

  state.write(line(rows[0]));
  state.ensureNewLine();
  state.write("| " + new Array(cols).fill("---").join(" | ") + " |");
  state.ensureNewLine();
  for (let i = 1; i < rows.length; i += 1) {
    state.write(line(rows[i]));
    state.ensureNewLine();
  }
  state.closeBlock(node);
}

const serializer = new MarkdownSerializer(
  {
    ...defaultMarkdownSerializer.nodes,
    // 库的默认符号是 `*`，但笔记里用户手写的是 `-`。
    // 产出格式要贴合习惯，否则「模型改没改字」这类逐字比较会一直误报。
    // 列表前缀由每一项自己的勾选态决定，所以要用带下标的 firstDelim。
    // 不能走默认的 bullet_list：它只认固定的 `* `。
    bullet_list: (state, node) => state.renderList(node, "  ", (index) => {
      const checked = node.child(index).attrs.checked;
      if (checked == null) return "- ";
      return checked ? "- [x] " : "- [ ] ";
    }),
    table: serializeTable,
    // 这两个不会单独出现（表格整块自己渲染），但序列化器要求节点表里存在，
    // 缺了会在异常结构上直接抛错。
    table_row: (state, node) => state.renderContent(node),
    table_cell: (state, node) => state.renderContent(node),
    table_header: (state, node) => state.renderContent(node),
  },
  {
    ...defaultMarkdownSerializer.marks,
    // 默认表里只有 em / strong / code / link 四种。
    // 删除线和高亮必须显式加进来，否则序列化到它们时直接抛错——
    // 这个错只会在「带删除线的笔记一保存」时出现，平时看不出来。
    strike: { open: "~~", close: "~~", mixable: true, expelEnclosingWhitespace: true },
    // 高亮：黄色是默认值，不写标记位，保证 `==x==` 这种老写法还能原样往返。
    highlight: {
      open: (state, mark) => {
        const color = mark.attrs.color;
        return color && color !== "y" ? `=={${color}}` : "==";
      },
      close: "==",
      // mixable 必须为 true：否则序列化器遇到中间夹着粗体/斜体的片段时
      // 不敢让高亮跨过去，会把 `==a **b** c==` 拆成 `==a== **==b==** ==c==`。
      mixable: true,
      expelEnclosingWhitespace: true,
    },
  },
);

/// 把 `- [ ] 甲` 认成任务项。
///
/// 在 HTML 上改而不是在文档里改：文档层要按位置逐条改，位置会随改动漂移，
/// 是最容易写出偏移错误的地方。HTML 层只需要看文本前缀。
function markTaskItems(holder) {
  holder.querySelectorAll("li").forEach((li) => {
    const first = li.firstElementChild;
    const target = first && first.tagName === "P" ? first : li;
    const textNode = target.firstChild;
    if (!textNode || textNode.nodeType !== 3) return;
    const match = /^\[([ xX])\]\s+/.exec(textNode.nodeValue);
    if (!match) return;
    textNode.nodeValue = textNode.nodeValue.replace(/^\[([ xX])\]\s+/, "");
    li.setAttribute("data-task", "true");
    li.setAttribute("data-checked", match[1].toLowerCase() === "x" ? "true" : "false");
  });
}

/// Markdown 文本 → 文档。空内容返回一个空段落，保证 doc 合法（block+）。
export function markdownToDoc(text) {
  const source = (text || "").replace(/\r\n?/g, "\n");
  const html = md.render(source);
  const holder = document.createElement("div");
  holder.innerHTML = html;
  markTaskItems(holder);
  const doc = PMDOMParser.fromSchema(schema).parse(holder);
  return doc.childCount ? doc : schema.node("doc", null, [schema.node("paragraph")]);
}

/// 文档 → Markdown 文本。
export function docToMarkdown(doc) {
  const out = serializer.serialize(doc, { tightLists: true });
  // 末尾统一去掉空行：存储层比较的是文本，多一个 \n 就会让「有没有改动」判错。
  return out.replace(/\n+$/, "");
}

/// 只取一段区间的 Markdown（选区处理用）。
export function sliceToMarkdown(doc, from, to) {
  const slice = doc.cut(from, to);
  const wrapper = schema.node("doc", null, [schema.node("paragraph")]);
  const target = wrapper.type.create(null, slice.content);
  return docToMarkdown(target);
}

/// 规范化：用于判断「模型改没改字」。只压空白，不动内容。
export function normalizeMarkdown(text) {
  return (text || "")
    .replace(/\r\n?/g, "\n")
    .replace(/[ \t]+$/gm, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// ── 粘贴：把「纯文本里的 HTML」救回来 ────────────────────────────
//
// 有些来源（微信、部分网页/编辑器）在剪贴板里只给纯文本，而那段纯文本
// 本身就是标记源码。直接插入的话，正文里会永久留下 `<ol><li></ol>` 这类字符串，
// 而且它会跟着笔记存进服务端——那是内容，不是渲染问题，事后只能手工删。
//
// 边界很清楚：**只在粘贴这一刻接受 HTML，转成节点后不留标签**。
// 存储格式仍然只有 Markdown 一种。

const HTML_START = /^\s*<(p|div|ul|ol|li|table|thead|tbody|tr|td|th|blockquote|pre|h[1-6]|hr)\b[^>]*>/i;
const HTML_END = /<\/[a-z][a-z0-9]*>\s*$/i;

/// 是不是「一段完整的 HTML 元素」。
/// 必须首尾都像标签，避免把正文里顺手写的 `<div` 当成 HTML 吞掉。
export function looksLikeHtml(text) {
  const trimmed = (text || "").trim();
  if (!trimmed) return false;
  return HTML_START.test(trimmed) && HTML_END.test(trimmed);
}

/// HTML 片段 → 可插入的切片。
/// innerHTML 只作用在游离节点上：脚本不会执行，图片也不会被请求；
/// 解析进我们的 schema 之后，不认识的标签一律被丢掉。
export function htmlToSlice(html) {
  const holder = document.createElement("div");
  holder.innerHTML = html;
  const doc = PMDOMParser.fromSchema(schema).parse(holder);
  return new Slice(doc.content, 0, 0);
}

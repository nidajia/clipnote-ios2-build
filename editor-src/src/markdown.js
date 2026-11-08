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
import { DOMParser as PMDOMParser } from "prosemirror-model";
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
  defaultMarkdownSerializer.marks,
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

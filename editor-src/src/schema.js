// 片记笔记编辑器的文档模型。
//
// 原则：只声明笔记真正用得到的节点，一个不多。
// 每多一个节点，Markdown 往返、粘贴清洗、工具栏都要多一处分支，
// 而这些分支在没有真机的情况下很难验全。
import { Schema } from "prosemirror-model";
import { addListNodes } from "prosemirror-schema-list";
import { tableNodes } from "prosemirror-tables";

/// 内联标记。顺序即嵌套顺序，序列化时从外往内包。
const marks = {
  strong: {
    parseDOM: [{ tag: "strong" }, { tag: "b" }],
    toDOM: () => ["strong", 0],
  },
  em: {
    parseDOM: [{ tag: "em" }, { tag: "i" }],
    toDOM: () => ["em", 0],
  },
  strike: {
    parseDOM: [{ tag: "s" }, { tag: "del" }, { tag: "strike" }],
    toDOM: () => ["s", 0],
  },
  code: {
    parseDOM: [{ tag: "code" }],
    toDOM: () => ["code", 0],
  },
  link: {
    attrs: { href: {}, title: { default: null } },
    inclusive: false,
    parseDOM: [{
      tag: "a[href]",
      getAttrs: (dom) => ({
        href: dom.getAttribute("href"),
        title: dom.getAttribute("title"),
      }),
    }],
    toDOM: (node) => ["a", { href: node.attrs.href, title: node.attrs.title }, 0],
  },
};

/// 块级节点。
const blocks = {
  doc: { content: "block+" },

  paragraph: {
    group: "block",
    content: "inline*",
    parseDOM: [{ tag: "p" }],
    toDOM: () => ["p", 0],
  },

  heading: {
    // 1–6 都收：从别处粘进来的 Markdown 可能有 h4–h6，
    // 不接受它们就等于静默丢格式。工具栏只暴露 1–3。
    attrs: { level: { default: 1 } },
    content: "inline*",
    group: "block",
    defining: true,
    parseDOM: [1, 2, 3, 4, 5, 6].map((level) => ({ tag: `h${level}`, attrs: { level } })),
    toDOM: (node) => [`h${node.attrs.level}`, 0],
  },

  blockquote: {
    content: "block+",
    group: "block",
    defining: true,
    parseDOM: [{ tag: "blockquote" }],
    toDOM: () => ["blockquote", 0],
  },

  horizontal_rule: {
    group: "block",
    parseDOM: [{ tag: "hr" }],
    toDOM: () => ["hr"],
  },

  code_block: {
    content: "text*",
    marks: "",
    group: "block",
    code: true,
    defining: true,
    attrs: { params: { default: "" } },
    parseDOM: [{
      tag: "pre",
      preserveWhitespace: "full",
      // markdown-it 把语言写在 <code class="language-js"> 上，
      // 不在 <pre> 上——这条踩过一次，代码块会静默丢掉语言标记。
      getAttrs: (dom) => {
        const code = dom.querySelector("code");
        const match = code ? /language-(\S+)/.exec(code.className || "") : null;
        return { params: match ? match[1] : "" };
      },
    }],
    toDOM: (node) => ["pre", { "data-params": node.attrs.params }, ["code", 0]],
  },

  text: { group: "inline" },

  hard_break: {
    inline: true,
    group: "inline",
    selectable: false,
    parseDOM: [{ tag: "br" }],
    toDOM: () => ["br"],
  },
};

const baseSchema = new Schema({ nodes: blocks, marks });

// 列表节点用 prosemirror-schema-list 提供的定义：
// list_item 的内容模型必须和段落对齐，否则嵌套列表会在某些路径上非法。
//
// 勾选态挂在 list_item 上，而不是另立 task_list / task_item 两个节点。
// 原因是真实的笔记里就这么写：
//     - 普通一条
//     - [ ] 任务一条
// 这两行在 CommonMark 里属于**同一个列表**。独立节点类型装不下混排，
// 解析时只能硬塞，结果就是「无序列表变成有序列表 + 多出一个空勾选框」。
const listBase = addListNodes(baseSchema.spec.nodes, "paragraph block*", "block");
const listItemSpec = listBase.get("list_item");

const withLists = listBase.update("list_item", {
  ...listItemSpec,
  attrs: { checked: { default: null } },
  parseDOM: [
    {
      tag: "li[data-task]",
      priority: 60,
      getAttrs: (dom) => ({ checked: dom.getAttribute("data-checked") === "true" }),
    },
    ...listItemSpec.parseDOM,
  ],
  toDOM: (node) => {
    const checked = node.attrs.checked;
    if (checked == null) return ["li", 0];
    return ["li", { "data-task": "true", "data-checked": String(checked) }, 0];
  },
});

const withTables = withLists.append(tableNodes({
  tableGroup: "block",
  cellContent: "paragraph",
  cellAttributes: {},
}));

export const schema = new Schema({ nodes: withTables, marks });

export const nodes = schema.nodes;
export const schemaMarks = schema.marks;

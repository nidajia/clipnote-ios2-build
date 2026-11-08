// 工具栏命令。
//
// 每条命令都是 (state, dispatch) => boolean，与 ProseMirror 的惯例一致：
// 不传 dispatch 时只回答「现在能不能做」，工具栏据此置灰。
import { toggleMark, setBlockType, wrapIn, lift } from "prosemirror-commands";
import { wrapInList, sinkListItem, liftListItem } from "prosemirror-schema-list";
import { InputRule, inputRules, textblockTypeInputRule, wrappingInputRule } from "prosemirror-inputrules";
import { nodes, schemaMarks, schema } from "./schema.js";

const isIn = (nodeType) => (state) => {
  const { $from } = state.selection;
  for (let d = $from.depth; d > 0; d -= 1) {
    if ($from.node(d).type === nodeType) return true;
  }
  return false;
};

export const markActive = (markType) => (state) => {
  const { from, $from, to, empty } = state.selection;
  if (empty) return !!markType.isInSet(state.storedMarks || $from.marks());
  return state.doc.rangeHasMark(from, to, markType);
};

export const blockActive = (nodeType, attrs) => (state) => {
  const { $from, to, node } = state.selection;
  if (node) return node.hasMarkup(nodeType, attrs);
  return to <= $from.end() && $from.parent.hasMarkup(nodeType, attrs);
};

export const inList = isIn(nodes.list_item);

export const bold = toggleMark(schemaMarks.strong);
export const italic = toggleMark(schemaMarks.em);
export const strike = toggleMark(schemaMarks.strike);
export const code = toggleMark(schemaMarks.code);

export const paragraph = setBlockType(nodes.paragraph);
export const heading = (level) => setBlockType(nodes.heading, { level });

export const blockquote = wrapIn(nodes.blockquote);
export const quoteActive = isIn(nodes.blockquote);
export const liftBlock = lift;

export const bulletList = wrapInList(nodes.bullet_list);
export const orderedList = wrapInList(nodes.ordered_list);
export const indent = sinkListItem(nodes.list_item);
export const outdent = liftListItem(nodes.list_item);

const findListItem = (state) => {
  const { $from } = state.selection;
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    if ($from.node(depth).type === nodes.list_item) {
      return { node: $from.node(depth), depth };
    }
  }
  return null;
};

export const inTask = (state) => {
  const found = findListItem(state);
  return Boolean(found) && found.node.attrs.checked != null;
};

/// 已经是一项就切换勾选；不在列表里就先包成无序列表，同时标成未勾选。
/// 一个按钮两种语义，是因为「再点一次变回普通段落」不比「勾掉它」更常用。
export const taskList = (state, dispatch, view) => {
  const found = findListItem(state);
  if (found) {
    if (dispatch) {
      const next = found.node.attrs.checked == null ? false : !found.node.attrs.checked;
      dispatch(state.tr.setNodeMarkup(state.selection.$from.before(found.depth), null, {
        checked: next,
      }));
    }
    return true;
  }

  const wrapped = wrapInList(nodes.bullet_list)(state, dispatch);
  if (wrapped && dispatch && view) {
    // 包完列表后位置全变了，必须拿**新状态**再算一次。
    const $pos = view.state.selection.$from;
    for (let depth = $pos.depth; depth > 0; depth -= 1) {
      if ($pos.node(depth).type === nodes.list_item) {
        view.dispatch(view.state.tr.setNodeMarkup($pos.before(depth), null, { checked: false }));
        break;
      }
    }
  }
  return wrapped;
};

export const horizontalRule = (state, dispatch) => {
  const { $from } = state.selection;
  // 引用块里插分隔线没有意义，直接拒绝，让按钮置灰。
  if (isIn(nodes.blockquote)(state)) return false;
  if (dispatch) {
    const pos = $from.depth > 0 ? $from.after() : state.selection.to;
    dispatch(state.tr.insert(pos, nodes.horizontal_rule.create()).scrollIntoView());
  }
  return true;
};

const codeBlockRaw = setBlockType(nodes.code_block, { params: "" });

/// 已在代码块里再点一次 = 变回正文。
/// 手机上没有 Esc，也没有 Mod-Enter，不给退路就是把用户关在代码块里。
export const setCodeBlock = (state, dispatch) => {
  const { $from } = state.selection;
  if ($from.parent.type === nodes.code_block) {
    return setBlockType(nodes.paragraph)(state, dispatch);
  }
  return codeBlockRaw(state, dispatch);
};

/// 空代码块里按回车就退出。有内容时回车仍然是换行——写代码的人要的是换行。
export const exitEmptyCodeBlock = (state, dispatch) => {
  const { $from } = state.selection;
  if ($from.parent.type !== nodes.code_block) return false;
  if ($from.parent.content.size > 0) return false;
  return setBlockType(nodes.paragraph)(state, dispatch);
};

function buildTable(rows, cols) {
  const cell = () => nodes.table_cell.create(null, nodes.paragraph.create());
  const row = () => nodes.table_row.create(null, Array.from({ length: cols }, cell));
  return nodes.table.create(null, Array.from({ length: rows }, row));
}

export const insertTable = (rows, cols) => (state, dispatch) => {
  const { $from } = state.selection;
  if (dispatch) {
    const pos = $from.depth > 0 ? $from.after() : state.selection.to;
    dispatch(state.tr.insert(pos, buildTable(rows, cols)).scrollIntoView());
  }
  return true;
};

/// 选中就加链接；没选中就把地址本身插进去，并且也带上链接标记。
/// 「什么都没发生」是最差的结果——用户会以为按钮坏了。
export const setLink = (href) => (state, dispatch) => {
  const clean = (href || "").trim();
  if (!clean) return false;
  const { empty, from, to } = state.selection;
  const mark = schemaMarks.link.create({ href: clean });
  if (dispatch) {
    let tr = state.tr;
    if (empty) {
      tr = tr.insertText(clean, from, to).addMark(from, from + clean.length, mark);
    } else {
      tr = tr.addMark(from, to, mark);
    }
    dispatch(tr.scrollIntoView());
  }
  return true;
};

export const removeLink = () => (state, dispatch) => {
  const { from, to, empty } = state.selection;
  if (empty || !state.doc.rangeHasMark(from, to, schemaMarks.link)) return false;
  if (dispatch) dispatch(state.tr.removeMark(from, to, schemaMarks.link));
  return true;
};

export const selectedText = (state) => {
  const { from, to } = state.selection;
  return state.doc.textBetween(from, to, "\n");
};

// ── 输入规则：让 `## ` `- ` `> ` 这类前缀在输入时就地成型 ──────────
// X3 验收的就是这条：打出 `## 标题` 之后不该再看见井号。

const hrRule = new InputRule(/^(?:---|\*\*\*|___)$/, (state, match, start, end) => {
  const tr = state.tr.delete(start, end);
  return tr.replaceRangeWith(start, start, nodes.horizontal_rule.create());
});

export const markdownInputRules = inputRules({
  rules: [
    textblockTypeInputRule(/^(#{1,6})\s$/, nodes.heading, (m) => ({ level: m[1].length })),
    wrappingInputRule(/^\s*>\s$/, nodes.blockquote),
    wrappingInputRule(/^\s*([-+*])\s$/, nodes.bullet_list),
    wrappingInputRule(/^(\d+)\.\s$/, nodes.ordered_list, (m) => ({ order: Number(m[1]) })),
    textblockTypeInputRule(/^```$/, nodes.code_block, () => ({ params: "" })),
    hrRule,
  ],
});

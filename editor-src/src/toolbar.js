// 自绘工具栏。
//
// 旧版用的是 Toast UI 的工具栏，它自带「放不下就折叠进 ⋯」的逻辑，
// 我们为了让按钮留在栏里横滑，得去改写它的 clientWidth。现在工具栏是自己的，
// 那条补丁整类消失：按钮不许收缩、容器横向滚动、右缘渐隐，三行 CSS 的事。
import { nodes, schemaMarks } from "./schema.js";
import * as cmd from "./commands.js";

const svg = (inner) =>
  `<svg viewBox="0 0 20 20" width="20" height="20" fill="none" stroke="currentColor" ` +
  `stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${inner}</svg>`;

const ICON = {
  heading: svg('<path d="M5 5v10M14 5v10M5 10h9"/><path d="M16.2 7.2l1.4-.9v5"/>'),
  bold: svg('<path d="M6.5 4h4.2a3.4 3.4 0 0 1 0 6.8H6.5z" stroke-width="1.8"/>' +
            '<path d="M6.5 10.8h4.8a3.6 3.6 0 0 1 0 7.2H6.5z" stroke-width="1.8"/>'),
  italic: svg('<path d="M9 4h6M6 16h6M12 4l-4 12"/>'),
  strike: svg('<path d="M4 10h12"/><path d="M12.4 6.2A3.2 3.2 0 0 0 6.6 8c0 1 .7 1.6 2.2 2"/>' +
              '<path d="M7.6 13.8A3.2 3.2 0 0 0 13.4 12"/>'),
  hr: svg('<path d="M3 10h14"/>'),
  quote: svg('<path d="M5 4v12"/><path d="M9 6h8M9 10h8M9 14h5"/>'),
  bullet: svg('<path d="M4 6h.01M4 10h.01M4 14h.01" stroke-width="2.6"/>' +
              '<path d="M8 6h8M8 10h8M8 14h8"/>'),
  ordered: svg('<path d="M8 6h8M8 10h8M8 14h8"/><path d="M3.4 5.4l.9-.6v3.4"/><path d="M3.2 12.6c0-.6.5-1 1.1-1s1.1.3 1.1.9c0 .9-2 1.4-2 2.5h2.2"/>'),
  indent: svg('<path d="M3 5h14M3 15h14"/><path d="M9 10h8"/><path d="M6 8l2 2-2 2"/>'),
  outdent: svg('<path d="M3 5h14M3 15h14"/><path d="M9 10h8"/><path d="M6 8l-2 2 2 2"/>'),
  table: svg('<path d="M3 4h14v12H3z"/><path d="M3 8h14M8 4v12"/>'),
  task: svg('<path d="M3.6 4.6h12.8v12.8H3.6z"/><path d="M6.6 11.2l2.3 2.3 4.5-4.9"/>'),
  link: svg('<path d="M8.5 11.5a3 3 0 0 0 4.3.3l2-2a3 3 0 0 0-4.3-4.3l-1.1 1.1"/>' +
            '<path d="M11.5 8.5a3 3 0 0 0-4.3-.3l-2 2a3 3 0 0 0 4.3 4.3l1.1-1.1"/>'),
  code: svg('<path d="M7.5 6L3.5 10l4 4M12.5 6l4 4-4 4"/>'),
  codeblock: svg('<path d="M3 4h14v12H3z"/><path d="M8 8l-2 2 2 2M12 8l2 2-2 2"/>'),
};

const GROUPS = [
  [
    { id: "heading", title: "标题", icon: ICON.heading, popup: "heading",
      active: (s) => s.selection.$from.parent.type === nodes.heading },
    { id: "bold", title: "加粗", icon: ICON.bold, run: () => cmd.bold, active: cmd.markActive(schemaMarks.strong) },
    { id: "italic", title: "斜体", icon: ICON.italic, run: () => cmd.italic, active: cmd.markActive(schemaMarks.em) },
    { id: "strike", title: "删除线", icon: ICON.strike, run: () => cmd.strike, active: cmd.markActive(schemaMarks.strike) },
  ],
  [
    { id: "hr", title: "分隔线", icon: ICON.hr, run: () => cmd.horizontalRule,
      enabled: (s) => !cmd.quoteActive(s) },
    { id: "quote", title: "引用", icon: ICON.quote, run: () => cmd.blockquote, active: cmd.quoteActive },
  ],
  [
    { id: "bullet", title: "无序列表", icon: ICON.bullet, run: () => cmd.bulletList,
      active: cmd.blockActive(nodes.bullet_list) },
    { id: "ordered", title: "有序列表", icon: ICON.ordered, run: () => cmd.orderedList,
      active: cmd.blockActive(nodes.ordered_list) },
    { id: "task", title: "任务清单", icon: ICON.task, run: () => cmd.taskList, active: cmd.inTask },
    { id: "indent", title: "缩进", icon: ICON.indent, run: () => cmd.indent, enabled: cmd.inList },
    { id: "outdent", title: "减少缩进", icon: ICON.outdent, run: () => cmd.outdent, enabled: cmd.inList },
  ],
  [
    { id: "table", title: "插入表格", icon: ICON.table, popup: "table" },
    { id: "link", title: "插入链接", icon: ICON.link, popup: "link" },
  ],
  [
    { id: "code", title: "内嵌代码", icon: ICON.code, run: () => cmd.code, active: cmd.markActive(schemaMarks.code) },
    { id: "codeblock", title: "代码块", icon: ICON.codeblock, run: () => cmd.setCodeBlock },
  ],
];

/**
 * 建工具栏。返回 { el, sync(state) }。
 * sync 在每次事务后调用，用来更新按下态与置灰态——
 * 按钮点了没反应之前，至少要先能看出「现在不能点」。
 */
export function createToolbar(view) {
  const el = document.createElement("div");
  el.className = "cn-tb";
  el.setAttribute("role", "toolbar");

  const buttons = new Map();
  const popups = [];

  const closeAllPopups = () => {
    popups.forEach((p) => p.classList.remove("open"));
    el.querySelectorAll(".cn-tb-btn[aria-expanded='true']")
      .forEach((b) => b.setAttribute("aria-expanded", "false"));
  };

  const makeButton = (spec) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "cn-tb-btn";
    b.dataset.cmd = spec.id;
    b.setAttribute("aria-label", spec.title);
    b.innerHTML = spec.icon;
    b.addEventListener("mousedown", (e) => e.preventDefault()); // 别抢走编辑区焦点
    b.addEventListener("click", (e) => {
      e.preventDefault();
      if (b.disabled) return;
      if (spec.popup) {
        const open = b.getAttribute("aria-expanded") === "true";
        closeAllPopups();
        if (!open) {
          b.setAttribute("aria-expanded", "true");
          openPopup(spec.popup, b);
        }
        return;
      }
      const command = spec.run();
      command(view.state, view.dispatch, view);
      view.focus();
    });
    buttons.set(spec.id, { spec, el: b });
    return b;
  };

  // 弹层：标题 / 表格 / 链接。全部自己画，位置贴着按钮。
  const popupLayer = document.createElement("div");
  popupLayer.className = "cn-tb-popup-layer";

  const openPopup = (kind, anchor) => {
    popupLayer.innerHTML = "";
    const panel = document.createElement("div");
    panel.className = "cn-tb-popup";
    const rect = anchor.getBoundingClientRect();
    panel.style.left = `${Math.max(6, Math.min(rect.left, window.innerWidth - 220))}px`;
    panel.style.top = `${Math.round(el.getBoundingClientRect().bottom + 4)}px`;

    if (kind === "heading") {
      [["正文", 0], ["标题 1", 1], ["标题 2", 2], ["标题 3", 3]].forEach(([label, level]) => {
        const item = document.createElement("button");
        item.type = "button";
        item.className = "cn-tb-item";
        item.textContent = label;
        item.addEventListener("click", () => {
          const command = level === 0 ? cmd.paragraph : cmd.heading(level);
          command(view.state, view.dispatch, view);
          closeAllPopups();
          view.focus();
        });
        panel.appendChild(item);
      });
    }

    if (kind === "table") {
      const grid = document.createElement("div");
      grid.className = "cn-tb-grid";
      const label = document.createElement("div");
      label.className = "cn-tb-grid-label";
      label.textContent = "选择表格大小";
      for (let r = 0; r < 5; r += 1) {
        for (let c = 0; c < 5; c += 1) {
          const cell = document.createElement("button");
          cell.type = "button";
          cell.className = "cn-tb-grid-cell";
          cell.dataset.r = String(r + 1);
          cell.dataset.c = String(c + 1);
          cell.setAttribute("aria-label", `${r + 1} 行 ${c + 1} 列`);
          cell.addEventListener("mouseenter", () => {
            grid.querySelectorAll(".cn-tb-grid-cell").forEach((n) => {
              const on = Number(n.dataset.r) <= r + 1 && Number(n.dataset.c) <= c + 1;
              n.classList.toggle("on", on);
            });
            label.textContent = `${r + 1} 行 × ${c + 1} 列`;
          });
          cell.addEventListener("click", () => {
            cmd.insertTable(r + 1, c + 1)(view.state, view.dispatch, view);
            closeAllPopups();
            view.focus();
          });
          grid.appendChild(cell);
        }
      }
      panel.appendChild(label);
      panel.appendChild(grid);
    }

    if (kind === "link") {
      const input = document.createElement("input");
      input.type = "url";
      input.className = "cn-tb-input";
      input.placeholder = "粘贴或输入链接";
      input.autocapitalize = "off";
      input.autocorrect = "off";
      input.spellcheck = false;
      const actions = document.createElement("div");
      actions.className = "cn-tb-actions";
      const ok = document.createElement("button");
      ok.type = "button";
      ok.className = "cn-tb-primary";
      ok.textContent = "插入";
      ok.addEventListener("click", () => {
        cmd.setLink(input.value)(view.state, view.dispatch, view);
        closeAllPopups();
        view.focus();
      });
      const cancel = document.createElement("button");
      cancel.type = "button";
      cancel.className = "cn-tb-secondary";
      cancel.textContent = "取消";
      cancel.addEventListener("click", () => {
        closeAllPopups();
        view.focus();
      });
      actions.append(ok, cancel);
      panel.append(input, actions);
      setTimeout(() => input.focus(), 0);
    }

    popupLayer.appendChild(panel);
    popups.length = 0;
    popups.push(panel);
    requestAnimationFrame(() => panel.classList.add("open"));
  };

  GROUPS.forEach((group, index) => {
    if (index > 0) {
      const divider = document.createElement("span");
      divider.className = "cn-tb-divider";
      el.appendChild(divider);
    }
    group.forEach((spec) => el.appendChild(makeButton(spec)));
  });

  // 右缘渐隐：只在「还能往右滑」时出现。位置按实际滚动量算，
  // 不是按「有没有溢出」算——溢出但已经滑到底，同样不该提示。
  const fade = document.createElement("div");
  fade.className = "cn-tb-fade";
  const syncFade = () => {
    const rest = el.scrollWidth - el.clientWidth - el.scrollLeft;
    fade.classList.toggle("on", rest > 2);
  };
  el.addEventListener("scroll", syncFade, { passive: true });
  window.addEventListener("resize", syncFade);
  requestAnimationFrame(syncFade);
  setTimeout(syncFade, 120);

  const wrapper = document.createElement("div");
  wrapper.className = "cn-tb-wrap";
  wrapper.append(el, fade, popupLayer);

  const sync = (state) => {
    buttons.forEach(({ spec, el: b }) => {
      b.classList.toggle("is-on", spec.active ? spec.active(state) : false);
      if (spec.enabled) {
        b.disabled = !spec.enabled(state);
      } else if (spec.run) {
        // 不传 dispatch 试运行一次：现在能不能做，由命令自己回答。
        b.disabled = !spec.run()(state, undefined, undefined);
      } else {
        b.disabled = false;
      }
    });
  };

  return { el: wrapper, sync, closePopups: closeAllPopups };
}

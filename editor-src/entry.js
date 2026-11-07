// 自带 ProseMirror 的打包入口。
//
// npm 里那个 dist/toastui-editor.js 把 prosemirror-* 当外部依赖，
// 直接内联会在运行时抛 "Cannot read properties of undefined (reading 'PluginKey')"，
// 结果 toastui 存在、Editor 不存在。这里用 esbuild 把所有依赖打进来。
import Editor from "@toast-ui/editor";
import "@toast-ui/editor/dist/toastui-editor.css";

window.toastui = { Editor };

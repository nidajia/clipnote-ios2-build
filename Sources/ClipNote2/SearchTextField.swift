import SwiftUI
import UIKit

/// 搜索输入框（UIKit 版）。
///
/// **为什么不用 SwiftUI 的 `TextField`**：中文输入法组词时，`text` 绑定会先变成
/// 拼音字母（"nihao"），列表跟着重算、视图跟着重排；只要中途有一个视图节点的
/// 增删或滚动导致输入框失去焦点，系统就会把当前拼音**当成正文提交**——
/// 用户看到的就是「打中文只出英文字母，然后就自动搜了」。
///
/// 这个壳子只做一件事：**组词期间不向外报值**（`markedTextRange != nil` 就返回），
/// 组词一结束（选中汉字）再一次性把汉字交给 SwiftUI。这样拼音阶段列表完全不动。
struct SearchTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        // 清空按钮交给 SwiftUI 那一颗（它要跟着 opacity 走），这里不要系统那颗，
        // 否则同一个位置会出现两个叉。
        field.clearButtonMode = .never
        field.font = UIFont(name: "PingFangSC-Regular", size: 15)
            ?? UIFont.systemFont(ofSize: 15)
        field.textColor = UIColor.label
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.addTarget(context.coordinator,
                        action: #selector(Coordinator.editingChanged(_:)),
                        for: .editingChanged)
        // 行高别撑高：外层已经给了固定 36pt 的高度
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // 组词中绝不覆盖：一覆盖，输入法会话就断了。
        guard field.markedTextRange == nil else { return }
        if field.text != text {
            field.text = text
        }
        if field.placeholder != placeholder {
            field.placeholder = placeholder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchTextField

        init(parent: SearchTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ field: UITextField) {
            // 关键：有 marked text 就是在组词（拼音还没上屏），一个字都不往外报
            if field.markedTextRange != nil { return }
            parent.text = field.text ?? ""
        }

        /// 组词结束（选中候选词）时系统会把 marked 清掉，这一步补报一次，
        /// 因为 `editingChanged` 在部分输入法下不会为「只上屏、没改长度」再触发。
        func textFieldDidChangeSelection(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            if parent.text != (field.text ?? "") {
                parent.text = field.text ?? ""
            }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            if field.markedTextRange == nil {
                parent.text = field.text ?? ""
            }
            field.resignFirstResponder()
            return true
        }
    }
}

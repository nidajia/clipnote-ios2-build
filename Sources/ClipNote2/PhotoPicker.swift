import PhotosUI
import SwiftUI

/// 系统相册选择器。
///
/// 用 PHPicker 而不是 UIImagePickerController：PHPicker 跑在独立进程里，
/// **不需要相册权限**。用别的方式一旦用户点过「不允许」，这条路就永久死了，
/// 而我们没有设置页可以引导他去改——那是真正的死路。
struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoPicker

        init(_ parent: PhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { self.parent.onPick(image) }
            }
        }
    }
}

extension UIImage {
    /// 压成适合放进笔记的 JPEG。
    ///
    /// 为什么要压：原图动辄 4–8MB，直接传会顶到服务端 6MB 上限；
    /// 而笔记里显示宽度最多 350pt，1600px 长边已经过剩。
    /// 压缩后通常 150–300KB，一次上传不到一秒。
    func clipnoteJPEG(maxSide: CGFloat = 1600, quality: CGFloat = 0.82) -> Data? {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let ratio = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: (size.width * ratio).rounded(),
                            height: (size.height * ratio).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

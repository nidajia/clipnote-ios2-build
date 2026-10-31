import XCTest
import SwiftUI
@testable import ClipNote2

/// 组件层快照：四个基础组件的所有状态，浅深各一张。
@MainActor
final class GallerySnapshotTests: XCTestCase {

    func testGalleryLight() throws {
        try SnapshotSupport.write(ComponentGallery(), name: "gallery-light", scheme: .light)
    }

    func testGalleryDark() throws {
        try SnapshotSupport.write(ComponentGallery(), name: "gallery-dark", scheme: .dark)
    }
}

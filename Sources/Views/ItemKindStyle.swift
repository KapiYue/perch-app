import SwiftUI

/// 条目类型的视觉规则（色标 + 图标）。
///
/// 色值直接取自 `perch-demo-v3.html` 的 `:root`，M5 做整体外观对齐时
/// 面板底色和行样式会跟上，但**色标本身就是这几个值**，不要再调。
extension ItemKind {

    /// 文本橙 / 链接绿 / 图片紫 / 文件蓝。
    var tint: Color {
        switch self {
        case .text: Color(red: 1.0, green: 0.624, blue: 0.039)
        case .link: Color(red: 0.188, green: 0.820, blue: 0.345)
        case .image: Color(red: 0.749, green: 0.353, blue: 0.949)
        case .file: Color.accentColor
        }
    }

    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

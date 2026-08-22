import SwiftUI

/// 固定态与「架已满」共用的琥珀色。
///
/// 和文本类型的色标是同一个值（`perch-demo-v3.html` 的 `:root` 里就一个橙），
/// 但语义不同：这里表示「要注意」，那里表示「这是文本」。
/// 同色不冲突是因为出现的位置完全分开 —— 琥珀的警示只出现在**行首固定标记**和**段标题**上，
/// 从来不会去染正文。
extension Color {
    static let perchAmber = Color(red: 1.0, green: 0.624, blue: 0.039)
}

/// 条目类型的视觉规则（色标 + 图标）。
///
/// 除代码外，色值直接取自 `perch-demo-v3.html` 的 `:root`，M5 做整体外观对齐时
/// 面板底色和行样式会跟上，但**色标本身就是这几个值**，不要再调。
extension ItemKind {

    /// 文本橙 / 链接绿 / 图片紫 / 代码青 / 文件蓝。
    var tint: Color {
        switch self {
        case .text: .perchAmber
        case .link: Color(red: 0.188, green: 0.820, blue: 0.345)
        case .image: Color(red: 0.749, green: 0.353, blue: 0.949)
        // demo v3 里没有代码这一类。取系统深色调色板的青（#64d2ff），
        // 和上面三个是同一族，且和文件的蓝（#0a84ff）在 26pt 图标上分得开。
        case .code: Color(red: 0.392, green: 0.824, blue: 1.0)
        case .file: Color.accentColor
        }
    }

    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .file: "doc"
        }
    }
}

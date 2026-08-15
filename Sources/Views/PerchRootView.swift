import SwiftUI

/// 面板根视图。
///
/// 结构是**上下分区**：上面剪贴板（文本列表），下面文件（网格）。
/// 剪贴板条目小而多，需要横着一眼扫完；文件大而少，需要缩略图和批量操作。
/// 混在一个列表里两边都憋屈 —— 这是返工一轮后确认的结论，不要合并回单一列表。
struct PerchRootView: View {

    @ObservedObject var state: PanelState
    @ObservedObject private var store = PerchStore.shared

    var body: some View {
        content
            // 窗口已经贴着屏幕物理顶部，内容往上滑出去就等于「收进刘海里」。
            // 动画对象是内容而不是窗口 frame：窗口尺寸每帧都变的话，
            // 里面的 SwiftUI 布局会跟着每帧重算，掉帧非常明显。
            .offset(y: state.isExpanded ? 0 : -state.contentHeight)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // 头部常驻：条目统计和 ⏸ 暂停按钮任何时候都要在，空架子上也一样。
            PanelHeaderView()
            Divider()

            if store.isEmpty {
                emptyState
            } else {
                if !store.clipboardItems.isEmpty {
                    ClipboardListView()
                }
                if !store.clipboardItems.isEmpty && !store.fileItems.isEmpty {
                    Divider()
                }
                if !store.fileItems.isEmpty {
                    FileGridView()
                }
            }
        }
        .frame(width: PerchPanel.width)
        .background(.ultraThinMaterial, in: bottomRoundedShape)
        .clipShape(bottomRoundedShape)
    }

    /// 面板从屏幕顶部往下展开，所以只有下面两个角是圆的。
    private var bottomRoundedShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("panel.empty.title")
                .font(.system(size: 13, weight: .medium))
            Text("panel.empty.hint")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

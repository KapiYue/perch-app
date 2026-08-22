import SwiftUI

/// 面板根视图。
///
/// 结构是**上下分区**：**上面文件（网格），下面剪贴板（文本列表）**。
/// 剪贴板条目小而多，需要横着一眼扫完；文件大而少，需要缩略图和批量操作。
/// 混在一个列表里两边都憋屈 —— 这是返工一轮后确认的结论，不要合并回单一列表。
///
/// 🚨 **顺序是「文件在上」，2026-08-21 定的，不要调回去。**
/// 早先是剪贴板在上。改的理由：文件网格高度基本固定且条目少，放上面不会把下面挤走；
/// 剪贴板条目多、要滚动、还带筛选 pills，放下面它涨到哪儿都不影响文件区。
/// 反过来的话，剪贴板一多就把文件区顶出可视范围 —— 而文件区恰恰是「拖进来又拖出去」
/// 那条主路径的落点，不能让它被挤掉。
/// 口径与参考稿 `docs/design/prototype` 的 `PerchNotch.tsx` 一致（上 Shelf、下 History）。
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
                if !store.fileItems.isEmpty {
                    FileGridView()
                        // 🚨 面板高度有半屏上限，装不下时 SwiftUI 会压缩里面的可滚动区域。
                        // 给文件区更高的布局优先级，让**剪贴板区去承担压缩** ——
                        // 反过来的话剪贴板一多就把文件区挤没了，
                        // 而文件区恰恰是「拖进来又拖出去」那条主路径的落点。
                        // 这也正是「文件在上、剪贴板在下」那条顺序规则要保的东西。
                        .layoutPriority(1)
                }
                if !store.fileItems.isEmpty && !store.clipboardItems.isEmpty {
                    Divider()
                }
                if !store.clipboardItems.isEmpty {
                    ClipboardListView()
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

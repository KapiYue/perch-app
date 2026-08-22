import SwiftUI

/// 面板头部：`栖架  12 条剪贴板 · 6 个文件 · 213 MB        ⏸ ⚙`
///
/// ⏸ **必须常驻可见**，不能收进设置里。
/// 本产品明确不做密码/敏感内容的启发式识别（复制密码会照常上架），
/// 一键暂停和「抹掉全部数据」是这个决定的配套补偿 —— 藏起来就等于没有。
struct PanelHeaderView: View {

    @ObservedObject private var store = PerchStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("panel.header.title")
                .font(.system(size: 12, weight: .semibold))

            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if store.isMonitoringPaused {
                Text("panel.header.paused")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ItemKind.text.tint)
            }

            headerButton(
                systemName: store.isMonitoringPaused ? "play.fill" : "pause.fill",
                help: store.isMonitoringPaused ? "panel.resume" : "panel.pause"
            ) {
                store.isMonitoringPaused.toggle()
            }

            headerButton(systemName: "gearshape", help: "panel.settings") {
                MenuBarController.openSettings()
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    private var summary: String {
        String(
            format: String(localized: "panel.header.summary"),
            store.clipboardItems.count,
            store.fileItems.count,
            Formatters.size(store.totalByteSize)
        )
    }

    /// 用 `clickAction` 而不是 SwiftUI `Button`：面板永远不是前台窗口，
    /// 每次点击都是「非活跃窗口的第一次点击」，得靠 AppKit 那层的 `acceptsFirstMouse`。
    private func headerButton(
        systemName: String,
        help: LocalizedStringKey,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 25, height: 25)
            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
            .help(help)
            .clickAction(action)
    }
}

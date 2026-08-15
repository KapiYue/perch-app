import SwiftUI

/// 剪贴板区：**文本列表**，不是横向卡片。
///
/// 文本内容用卡片是空间浪费，横着扫比竖着扫累 —— 这是返工一轮后确认的结论。
///
/// 每行结构：
/// `[⌘N 序号] [26pt 类型图标/缩略图] [内容预览，单行截断] [多久前 · 多久后清理] [☆ 固定] [✕ 移除]`
struct ClipboardListView: View {

    @ObservedObject private var store = PerchStore.shared
    @ObservedObject private var taker = ClipboardTaker.shared

    /// 列表最大高度，超出滚动。
    static let maxHeight: CGFloat = 186

    /// 「3 分钟前」得自己走，否则面板开着的时候这行字会一直停在原地。
    /// 30 秒一跳够用 —— 显示精度本来就只到分钟。
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("clipboard.section")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(store.clipboardItems.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index)
                    }
                }
            }
            .frame(maxHeight: Self.maxHeight)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .onReceive(clock) { now = $0 }
    }

    // MARK: - 行

    private func row(_ item: PerchItem, index: Int) -> some View {
        let isTaken = taker.recentlyTakenID == item.id

        return HStack(spacing: 6) {
            // 起拖 + 单击 / 双击都挂在内容那半边。
            // 整行都盖上的话，右边的 ☆ / ✕ 会被起拖层接管，永远点不到。
            content(item, index: index)
                .dragOut([item]) { click in handle(click, on: item) }

            if isTaken {
                takenBadge
            }

            actionButton(
                systemName: item.isPinned ? "star.fill" : "star",
                tint: item.isPinned ? Color(red: 1.0, green: 0.624, blue: 0.039) : .secondary,
                help: item.isPinned ? "row.unpin" : "row.pin"
            ) {
                store.togglePin(item.id)
            }

            actionButton(systemName: "xmark", tint: .secondary, help: "row.remove") {
                store.remove(item.id)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(rowBackground(isTaken: isTaken), in: .rect(cornerRadius: 9))
        .overlay {
            // 取回反馈：整行变绿 + 描边，1.1 秒后连同面板一起收走。
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(ItemKind.link.tint, lineWidth: isTaken ? 1 : 0)
        }
    }

    private func rowBackground(isTaken: Bool) -> Color {
        isTaken ? ItemKind.link.tint.opacity(0.18) : Color.secondary.opacity(0.10)
    }

    private func content(_ item: PerchItem, index: Int) -> some View {
        HStack(spacing: 9) {
            // 前 9 条才有 ⌘N。位置固定留出来，否则第 10 条起整列会往左跳一下。
            Text(index < 9 ? "⌘\(index + 1)" : "")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(width: 22)

            icon(item)
                .frame(width: 26, height: 26)
                .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    // 链接用绿色。其余类型的色标在行首图标上，正文保持默认色 ——
                    // 一整列彩色正文会让「一眼扫完」变难。
                    .foregroundStyle(item.kind == .link ? ItemKind.link.tint : .primary)

                Text(meta(item))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    /// 图片显示真实缩略图，其余显示类型图标。
    ///
    /// 只认 `thumbPath`，不拿 `blobPath` 顶替 —— 那是原图，一张截图三五 MB，
    /// 每次重绘都要解一遍，列表滚起来会明显发涩。
    @ViewBuilder
    private func icon(_ item: PerchItem) -> some View {
        if let thumbPath = item.thumbPath,
           let image = NSImage(contentsOf: BlobStore.absoluteURL(forRelativePath: thumbPath)) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                item.kind.tint.opacity(0.16)
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(item.kind.tint)
            }
        }
    }

    private func actionButton(
        systemName: String,
        tint: Color,
        help: LocalizedStringKey,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 23, height: 23)
            .contentShape(.rect)
            .help(help)
            .clickAction(action)
    }

    private var takenBadge: some View {
        Text("clipboard.copied")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ItemKind.link.tint, in: .capsule)
            .transition(.opacity)
    }

    // MARK: - 取出

    private func handle(_ click: ClickContext, on item: PerchItem) {
        // 双击 = 切换固定。第一下已经复制过并排好了「1.1 秒后收起」，
        // 第二下要把那个收起撤掉，否则刚固定完面板就溜走了。
        if click.clickCount >= 2 {
            store.togglePin(item.id)
            taker.cancelTake()
        } else {
            taker.take(item)
        }
    }

    // MARK: - 「多久前 · 多久后清理」

    /// 两个 formatter 都不是 Sendable，标 `@MainActor` 让它们跟着视图走，
    /// 比每次重绘现建一个便宜得多（formatter 的初始化不轻）。
    @MainActor private static let elapsed: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // 刚上架的那一条差值几乎是 0，`.numeric` 会算成「0 秒前」；`.named` 给「现在」。
        formatter.dateTimeStyle = .named
        return formatter
    }()

    @MainActor private static let remaining: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        // 只留最大的那一档：「11 小时 34 分钟后清理」在 9.5pt 上就是一团糊。
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .short
        return formatter
    }()

    private func meta(_ item: PerchItem) -> String {
        // 🚨 参照点要夹一下。`now` 每 30 秒才跳一次，而条目是随时上架的：
        // 上一次跳之后新增的那条 `createdAt > now`，直接算会显示成「1 秒**后**」。
        let reference = max(now, item.createdAt)
        let ago = Self.elapsed.localizedString(for: item.createdAt, relativeTo: reference)

        // 固定项永不过期，不显示倒计时（M3 的清理会跳过它们）。
        if item.isPinned {
            return "\(ago) · \(String(localized: "item.pinned"))"
        }

        let expiry = item.createdAt.addingTimeInterval(Preferences.retentionInterval)
        guard expiry > now, let left = Self.remaining.string(from: now, to: expiry) else {
            return ago
        }
        return String(format: String(localized: "item.meta.expires"), ago, left)
    }
}

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
    ///
    /// 🚨 这个数曾经是 186（约 4 行）。200 条内容全被挤在四行高的框里，
    /// 用户根本看不出「200 条是不是真的都在」—— 2026-08-22 的真机反馈就是这一条。
    /// 现在给足高度，让面板自己按内容长起来；真正的上限由
    /// `PerchPanel.fitToContentAndPosition` 那条「不超过半屏」兜着。
    static let maxHeight: CGFloat = 420

    /// 「3 分钟前」得自己走，否则面板开着的时候这行字会一直停在原地。
    /// 30 秒一跳够用 —— 显示精度本来就只到分钟。
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("clipboard.section")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                // 「183 / 200」。写出上限，满了之后最旧的那条被淘汰就不再是无声的了 ——
                // 用户能看见自己正贴着上限跑。
                Text("\(store.clipboardItems.count) / \(Janitor.clipboardLimit)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(isFull ? Color.perchAmber : .secondary)

                // 🚨 满额时必须明说。
                // 行内那句「19 分钟后清理」只讲了保存时长这一条规则，
                // 而满额之后最旧那条的真实寿命是「**到下一次复制为止**」——
                // 淘汰按条数、清理按时长，两条规则互相独立。
                // 2026-08-22 真机上就踩了这个坑：用户盯着一条「19 分钟后清理」的记录，
                // 结果截了两张图（截图会落剪贴板 = 两条新内容）就把它顶掉了，
                // 第一反应是「数据被谁删了」。倒计时只说一半，就是在误导。
                if isFull {
                    Text("clipboard.limit.badge")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.perchAmber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.perchAmber.opacity(0.16), in: .rect(cornerRadius: 4))
                        .help("clipboard.limit.help")
                }

                Spacer(minLength: 6)

                filterPills
            }

            let items = store.visibleClipboardItems

            if items.isEmpty {
                // 筛选筛空了。这里不能什么都不画 ——
                // 面板会缩成一条，用户会以为内容被清掉了。
                Text("clipboard.filter.empty")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                        }
                    }
                }
                .frame(maxHeight: Self.maxHeight)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .onReceive(clock) { now = $0 }
    }

    // MARK: - 类型筛选 pills

    /// 全部 / 文本 / 链接 / 图片 / 代码，**单选**。
    ///
    /// 只改显示不改数据：切换 pill 不会动 `clipboardItems` 一根汗毛，
    /// 也不会把被筛掉的条目提前清理。收起面板即回到「全部」。
    private var filterPills: some View {
        HStack(spacing: 3) {
            ForEach(ClipboardFilter.allCases, id: \.self) { filter in
                pill(filter)
            }
        }
    }

    private func pill(_ filter: ClipboardFilter) -> some View {
        let isOn = store.clipboardFilter == filter
        // 「全部」没有类型色，跟着强调色走。
        let tint = filter.kind?.tint ?? Color.accentColor

        return Text(LocalizedStringKey(filter.titleKey))
            .font(.system(size: 10, weight: isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? tint : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isOn ? tint.opacity(0.18) : Color.secondary.opacity(0.10),
                in: .capsule
            )
            .contentShape(.capsule)
            // 和头部按钮同一个理由：面板永远不是前台窗口，
            // SwiftUI `Button` 的第一次点击会被系统吞掉。
            .clickAction {
                guard store.clipboardFilter != filter else { return }
                store.clipboardFilter = filter
                // 条目少了面板要跟着变矮，否则内容会吊在一个空壳的中间。
                PanelController.shared.refitToContent()
            }
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
                help: item.isPinned
                    ? String(localized: "row.unpin")
                    : String(localized: "row.pin")
            ) {
                store.togglePin(item.id)
            }

            actionButton(
                systemName: "xmark",
                tint: .secondary,
                help: String(localized: "row.remove")
            ) {
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

    /// 行首那一格画什么。
    ///
    /// - 未筛选：前 9 条画 `⌘1`–`⌘9`，因为此刻可见顺序**就是**全表顺序，按下去所见即所得。
    /// - 筛选生效：改画普通序号 `1.`、`2.`……
    ///
    /// 🚨 筛选时**必须**换掉徽标。`⌘N` 始终指全表第 N 条（见 `PerchStore.clipboardItem(at:)`），
    /// 而筛选后可见的第 1 行往往不是全表第 1 条 —— 两者同时出现就是在骗用户。
    /// 参考稿 `ClipboardHistoryZone.tsx` 也是这么处理的（`isTopNine` 要求 `activeFilter === 'all'`）。
    private func shortcutLabel(at index: Int) -> String {
        guard store.clipboardFilter == .all else { return "\(index + 1)." }
        return index < 9 ? "⌘\(index + 1)" : ""
    }

    private func content(_ item: PerchItem, index: Int) -> some View {
        HStack(spacing: 9) {
            // 位置固定留出来，否则第 10 条起整列会往左跳一下。
            Text(shortcutLabel(at: index))
                .font(.system(size: 9.5))
                // 同上：9.5pt 的字压在半透明材质上，`.tertiary` 是看不清的。
                .foregroundStyle(.secondary)
                .frame(width: 22)

            icon(item)
                .frame(width: 26, height: 26)
                .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    // 语言标签只有代码类型才有，而且一定有 ——
                    // 认不出语言的片段根本不会被判成 `.code`（见 CodeDetector）。
                    if item.kind == .code, let language = item.language {
                        Text(language)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(ItemKind.code.tint)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(ItemKind.code.tint.opacity(0.16), in: .rect(cornerRadius: 3))
                            .fixedSize()
                    }

                    Text(item.preview)
                        .font(.system(size: 12, design: item.kind == .code ? .monospaced : .default))
                        .lineLimit(1)
                        // 链接用绿色。其余类型的色标在行首图标上，正文保持默认色 ——
                        // 一整列彩色正文会让「一眼扫完」变难。
                        // 代码不换颜色，只换等宽字体：缩进和对齐才是它的辨识特征。
                        .foregroundStyle(item.kind == .link ? ItemKind.link.tint : .primary)
                }

                Text(meta(item))
                    .font(.system(size: 9.5))
                    // 🚨 不能用 `.tertiary`。它大约只有 25% 不透明度，
                    // 压在 `.ultraThinMaterial` 上（背后还透着别的 App 的内容）几乎看不见 ——
                    // 2026-08-22 真机反馈「字体颜色和背景一致」说的就是这一行。
                    // 倒计时看不见等于「去重有没有重置计时」根本没法验。
                    // 彻底的解法是 M5 把面板换成参考稿那个不透明深色底，这里先把对比度提上来。
                    .foregroundStyle(.secondary)
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
        help: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 23, height: 23)
            .contentShape(.rect)
            // 提示交给 `clickAction` 挂到 AppKit 那层上。用 SwiftUI 的 `.help` 是不行的：
            // 点击层是一层盖在上面的不透明视图，鼠标停住时命中的是它，
            // 底下注册的那条提示永远查不到 —— 这两个按钮的 tooltip 一直没显示过。
            .clickAction(help: help, action)
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

    /// 架上是不是已经贴着上限了。
    ///
    /// 固定项不参与淘汰，固定项多到超过 200 时总数会突破上限，所以用 `>=` 不用 `==`。
    private var isFull: Bool {
        store.clipboardItems.count >= Janitor.clipboardLimit
    }

    // MARK: - 「多久前 · 多久后清理」

    private func meta(_ item: PerchItem) -> String {
        Formatters.meta(Formatters.elapsed(since: item.createdAt, now: now), for: item, now: now)
    }
}

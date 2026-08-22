import AppKit

/// 后台剪贴板监听 —— **本产品唯一的立身之本**。
///
/// `Timer` 每 0.5 秒轮询 `NSPasteboard.general.changeCount`
/// （系统没有提供剪贴板变更通知 API，轮询是唯一可行方式），
/// changeCount 变了才读内容，平时几乎不耗 CPU。
///
/// 明确不做：任何密码 / 敏感内容的启发式识别。复制密码会照常上架，
/// 这是产品决定 —— 对应的补偿是常驻可见的暂停按钮和「抹掉全部数据」。
/// 唯一的例外是下面这个 `ConcealedType`，那不是猜内容，是读来源 App 自己打的标记。
@MainActor
final class ClipboardWatcher {

    static let shared = ClipboardWatcher()

    /// macOS 上的社区约定：1Password / Bitwarden 等在剪贴板上打这个标记，
    /// 表示「这条是机密内容，别记」。
    ///
    /// 认它**不违反**「不做密码识别」那条产品决定 —— 我们没有去猜内容像不像密码，
    /// 只是尊重来源 App 的显式声明。可靠性完全取决于来源 App 规不规范打标，
    /// 所以对应的设置项**默认关闭**，官网隐私页也是这么写的。
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// 轮询间隔。再短对 CPU 不划算，再长会有明显的「复制了没上架」延迟。
    static let pollInterval: TimeInterval = 0.5

    private var timer: Timer?

    /// 记录上一次看到的 changeCount，初始值取当前值，
    /// 避免启动瞬间把用户早前复制的内容当成新内容抓进来。
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    private(set) var isRunning = false

    /// 这次变更还允许再读几次。
    ///
    /// 🚨 **为什么需要重试**：`declareTypes` 会**先把剪贴板清空、把 changeCount 加一，
    /// 数据是随后才写进去的**。轮询若恰好落进这个窗口，读到的是「变了，但什么都没有」——
    /// 要是这时把 changeCount 记下当作处理过了，用户复制的那条内容就**永久丢失**，
    /// 而且不报错、没日志，表现就是「我明明复制了，架上没有」。
    ///
    /// 实测（2026-08-22，用一个「声明类型后延迟 0.2–0.4 秒才写数据」的模拟来源 App）：
    /// 修之前 6 次丢 3 次。真实 App 的这个窗口通常不到一毫秒，所以概率低 —— 但不是零，
    /// 而对剪贴板工具来说「偶尔静默吞掉一条」是最不能接受的失败方式。
    private var pendingReads = 0

    /// 重试预算。3 次 × 0.5 秒 = 1.5 秒，足够覆盖来源 App 写数据的耗时。
    ///
    /// 必须有上限：有些 App 只往剪贴板放我们不认识的私有类型（既不是图片、文件也不是文本），
    /// 那种情况永远读不出东西，没有预算的话就会每 0.5 秒空转一次直到下次复制。
    private static let maxReadAttempts = 3

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardWatcher.shared.tick() }
        }
        // 🚨 必须加进 `.common` 模式。
        // 默认的 `.default` 在菜单弹开、拖拽、窗口 resize 这些 tracking runloop 期间会整个停摆，
        // 表现是「按住鼠标的时候复制不上架」，而且事后也补不回来（changeCount 已经被下一次覆盖）。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// **我们自己往剪贴板写完之后必须调这个。**
    ///
    /// 「单击整行取回」会写一次剪贴板，changeCount 跟着变。不打这个招呼的话，
    /// 下一次轮询会把刚取出的内容当成用户新复制的内容再上架一遍，
    /// 于是每取一次就多一条重复项。
    func acknowledgeSelfWrite() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - 轮询

    private func tick() {
        let pasteboard = NSPasteboard.general

        if pasteboard.changeCount != lastChangeCount {
            // 先记下来再判断暂停：暂停期间也要把 changeCount 吃掉，
            // 否则一恢复监听就会把暂停期间复制过的东西倒灌进来 —— 暂停就白暂停了。
            lastChangeCount = pasteboard.changeCount
            // 新的一次变更，重试预算重置。
            pendingReads = Self.maxReadAttempts
        } else if pendingReads == 0 {
            // 没变化，也没有读空待重试的 —— 绝大多数轮询都停在这里，几乎不耗 CPU。
            return
        }

        guard !PerchStore.shared.isMonitoringPaused else {
            pendingReads = 0
            return
        }

        // 机密标记同理：判定要在读内容**之前**，命中就直接返回，
        // 内容一个字节都不读、更不落盘。
        if Preferences.skipConcealedContent, isConcealed(pasteboard) {
            pendingReads = 0
            return
        }

        if ingest(pasteboard) {
            pendingReads = 0
        } else {
            // 读空了。**不要**把这次变更算作处理过 —— 留着下一轮再读一次，
            // 很可能只是来源 App 还没把数据写完。
            pendingReads -= 1
        }
    }

    private func isConcealed(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(Self.concealedType) ?? false
    }

    /// 判定优先级：图片 > 文件URL > 链接 > 代码 > 纯文本（和 `DropIngestor` 保持一致）。
    ///
    /// 落地一律走 `DropIngestor` 的三个入口，不在这里另写一份 ——
    /// blobs/ 的写法、缩略图、去重键格式只能有一套。
    /// 返回是否真的读到了可处理的内容。读空（false）意味着要重试。
    @discardableResult
    private func ingest(_ pasteboard: NSPasteboard) -> Bool {
        if let data = DropIngestor.imageData(in: pasteboard) {
            DropIngestor.ingestImage(data)
            return true
        }

        // 复制文件走文件区，不进剪贴板区。
        let urls = DropIngestor.fileURLs(in: pasteboard)
        if !urls.isEmpty {
            DropIngestor.ingestFiles(urls)
            return true
        }

        // 链接和纯文本的分流在 ingestText 里（判定就看 http/https 前缀）。
        if let text = pasteboard.string(forType: .string) {
            DropIngestor.ingestText(text)
            return true
        }

        return false
    }
}

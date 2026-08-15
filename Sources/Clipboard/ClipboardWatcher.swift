import AppKit

/// 后台剪贴板监听 —— **本产品唯一的立身之本**。
///
/// `Timer` 每 0.5 秒轮询 `NSPasteboard.general.changeCount`
/// （系统没有提供剪贴板变更通知 API，轮询是唯一可行方式），
/// changeCount 变了才读内容，平时几乎不耗 CPU。
///
/// 明确不做：任何密码 / 敏感内容的启发式识别。复制密码会照常上架，
/// 这是产品决定 —— 对应的补偿是常驻可见的暂停按钮和「抹掉全部数据」。
@MainActor
final class ClipboardWatcher {

    static let shared = ClipboardWatcher()

    /// 轮询间隔。再短对 CPU 不划算，再长会有明显的「复制了没上架」延迟。
    static let pollInterval: TimeInterval = 0.5

    private var timer: Timer?

    /// 记录上一次看到的 changeCount，初始值取当前值，
    /// 避免启动瞬间把用户早前复制的内容当成新内容抓进来。
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    private(set) var isRunning = false

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
        guard pasteboard.changeCount != lastChangeCount else { return }

        // 先记下来再判断暂停：暂停期间也要把 changeCount 吃掉，
        // 否则一恢复监听就会把暂停期间复制过的东西倒灌进来 —— 暂停就白暂停了。
        lastChangeCount = pasteboard.changeCount
        guard !PerchStore.shared.isMonitoringPaused else { return }

        ingest(pasteboard)
    }

    /// 判定优先级：图片 > 文件URL > 链接 > 纯文本（和 `DropIngestor` 保持一致）。
    ///
    /// 落地一律走 `DropIngestor` 的三个入口，不在这里另写一份 ——
    /// blobs/ 的写法、缩略图、去重键格式只能有一套。
    private func ingest(_ pasteboard: NSPasteboard) {
        if let data = DropIngestor.imageData(in: pasteboard) {
            DropIngestor.ingestImage(data)
            return
        }

        // 复制文件走文件区，不进剪贴板区。
        let urls = DropIngestor.fileURLs(in: pasteboard)
        if !urls.isEmpty {
            DropIngestor.ingestFiles(urls)
            return
        }

        // 链接和纯文本的分流在 ingestText 里（判定就看 http/https 前缀）。
        if let text = pasteboard.string(forType: .string) {
            DropIngestor.ingestText(text)
        }
    }
}

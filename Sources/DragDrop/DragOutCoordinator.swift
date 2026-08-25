import AppKit
import UniformTypeIdentifiers

/// 一次拖出要送走什么。
///
/// 分成两种而不是「多传一个 isZip 参数」，是因为两者的**数量关系不一样**：
/// `.items` 是 N 个条目 → N 个文件，`.zip` 是 N 个条目 → **1 个**文件。
enum DragPayload: Sendable {

    /// 逐个送走。多选拖出走这条。
    case items([PerchItem])

    /// 打包成一个 zip 再送走。批量操作条上的「打包 ZIP」走这条。
    case zip([PerchItem])
}

/// 统一调度两条拖出路径。
///
/// 策略（`pasteboardWriter(for:)`）：
/// - `blobs/` 里已经有本体的条目 → 写 `.fileURL`，让系统自己拷；
/// - 磁盘上还不存在的条目（文本、链接，以及 ZIP 打包）→ 写 `FilePromiseProvider`，松手才生成。
///
/// 对外只暴露 `beginDrag(_:from:event:)`，多选拖出天然支持：
/// 一个 session 里放多个 `NSDraggingItem` 即可。
@MainActor
final class DragOutCoordinator: NSObject {

    /// 单例不是为了图省事 —— `NSFilePromiseProvider.delegate` 是 weak 的，
    /// delegate 必须活得比整个拖拽过程长，用长生命周期对象最稳妥。
    static let shared = DragOutCoordinator()

    private override init() { super.init() }

    /// 承诺文件的落盘队列。
    ///
    /// 不能用 `.main`：目标 App 在等我们写完，主线程写大文件会把面板和菜单栏一起卡住。
    /// 不实现 `operationQueueForFilePromiseProvider` 的话系统默认就用主队列。
    /// ZIP 打包也在这个队列上跑，同理。
    private let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.joy-coder.perch.file-promise"
        // 串行。并发写没有收益，反而让「拖 10 个文件」变成 10 个线程抢磁盘。
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    // MARK: - 发起拖拽

    /// 从 `view` 开始一次拖出。`event` 必须是那次 **mouseDown** 事件，
    /// 传 mouseDragged 进来的话拖拽图像的起点会跳一下。
    func beginDrag(_ payload: DragPayload, from view: NSView & NSDraggingSource, event: NSEvent) {
        let origin = view.convert(event.locationInWindow, from: nil)

        // (写进 pasteboard 的对象, 拖拽图像) —— 两种 payload 的差别到这里就收敛完了。
        let entries: [(writer: NSPasteboardWriting, image: NSImage)]

        switch payload {
        case .items(let items):
            entries = items.compactMap { item in
                guard let writer = pasteboardWriter(for: item) else { return nil }
                return (writer, dragImage(for: item))
            }
        case .zip(let items):
            guard let writer = zipWriter(for: items) else { return }
            entries = [(writer, zipDragImage())]
        }

        let draggingItems: [NSDraggingItem] = entries.map { entry in
            let draggingItem = NSDraggingItem(pasteboardWriter: entry.writer)
            let image = entry.image
            // 不设 draggingFrame 的话拖起来**完全没有图像**，用户会以为功能坏了。
            draggingItem.setDraggingFrame(
                NSRect(
                    x: origin.x - image.size.width / 2,
                    y: origin.y - image.size.height / 2,
                    width: image.size.width,
                    height: image.size.height
                ),
                contents: image
            )
            return draggingItem
        }

        guard !draggingItems.isEmpty else { return }

        let session = view.beginDraggingSession(with: draggingItems, event: event, source: view)
        // 多个条目堆成一摞，跟 Finder 的多选拖拽一致。
        session.draggingFormation = .stack
    }

    /// 一次拖出结束后的收尾：选中态清掉，面板收起。
    ///
    /// 放在这里而不是视图里，是因为多选拖出时**每个格子都有一个起拖层**，
    /// 收尾逻辑只能有一份，否则会重复执行。
    func dragOutEnded() {
        PerchStore.shared.clearSelection()
        PanelController.shared.dragOutEnded()
    }

    // MARK: - 两条路径的分派

    /// 返回写进 pasteboard 的对象。`nil` 表示这条目前拖不出去（本体丢了）。
    func pasteboardWriter(for item: PerchItem) -> NSPasteboardWriting? {
        if let url = existingFileURL(for: item) {
            // 路径一：本体已经在 blobs/ 里。
            // `NSURL` 而不是 `URL` —— `NSPasteboardWriting` 是 ObjC 协议，
            // Swift 的值类型 `URL` 并不遵守它。
            return url as NSURL
        }

        // 路径二：磁盘上还没有这个文件，承诺到松手时再生成。
        guard let promise = promisedFile(for: item) else { return nil }
        return FilePromiseProvider(promise: promise, delegate: self)
    }

    /// 把若干条目打包成一个 zip 的承诺。
    ///
    /// 用承诺而不是「先压好再拖」有两个实打实的好处：
    /// ① 用户中途放弃（拖到一半松手在无效区域）就完全不会压，不留垃圾；
    /// ② 压缩发生在 `writeQueue` 上，几百 MB 也不会把面板冻住。
    func zipWriter(for items: [PerchItem]) -> NSPasteboardWriting? {
        let sources = existingFileURLs(for: items)
        guard !sources.isEmpty else { return nil }

        let name = Self.zipName(for: items)
        // 闭包里只留 [URL] 和 String，都是 Sendable —— 后台队列碰不到 PerchStore。
        let promise = PromisedFile(
            filename: "\(name).zip",
            type: .zip,
            write: { destination in
                try ZipPacker.pack(sources, archiveName: name, to: destination)
            }
        )
        return FilePromiseProvider(promise: promise, delegate: self)
    }

    /// zip 的名字，同时也是解压出来那层文件夹的名字。
    ///
    /// 单个文件用它自己的主名（`report.pdf` → `report.zip`），和访达右键「压缩」一致；
    /// 多个文件用「栖架 N 项」，比 `归档.zip` 更认得出是从哪儿来的。
    static func zipName(for items: [PerchItem]) -> String {
        if items.count == 1 {
            return ZipPacker.sanitized((items[0].preview as NSString).deletingPathExtension)
        }
        return ZipPacker.sanitized(
            String(format: String(localized: "files.zip.name"), items.count)
        )
    }

    /// 条目本体在磁盘上真实存在时返回它的 URL。
    private func existingFileURL(for item: PerchItem) -> URL? {
        guard let blobPath = item.blobPath else { return nil }
        let url = BlobStore.absoluteURL(forRelativePath: blobPath)
        // 存在性必须真查一次：blobs/ 可能被用户手动清过，
        // 这时写一个指向空气的 .fileURL 出去，目标 App 只会收到一个报错弹窗。
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 一批条目里本体还在的那些。打包、导出、AirDrop 都以它为准。
    func existingFileURLs(for items: [PerchItem]) -> [URL] {
        items.compactMap { existingFileURL(for: $0) }
    }

    /// 为「磁盘上还不存在」的条目描述一个承诺。
    private func promisedFile(for item: PerchItem) -> PromisedFile? {
        switch item.kind {
        case .text, .link, .code:
            let content = item.preview
            // 代码按语言给扩展名（`.swift` / `.py` / `.json`），拖到编辑器里
            // 才有高亮。认不出扩展名就退回 .txt —— 内容一个字节都不差。
            let ext = item.kind == .code
                ? (CodeDetector.fileExtension(for: item.language) ?? "txt")
                : "txt"
            return PromisedFile(
                filename: Self.sanitizedFilename(from: content, extension: ext),
                type: UTType(filenameExtension: ext) ?? .plainText,
                // 显式 UTF-8，不带 BOM。系统默认编码在中文环境下会写成乱码。
                write: { destination in
                    try Data(content.utf8).write(to: destination, options: .atomic)
                }
            )
        case .image, .file:
            // 图片和文件的本体一定在 blobs/ 里（见 PerchItem 的硬性约定），
            // 走到这里说明本体丢了，拖出没有意义。
            return nil
        }
    }

    // MARK: - 拖拽图像

    private func dragImage(for item: PerchItem) -> NSImage {
        let icon = NSWorkspace.shared.icon(for: contentType(for: item))
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }

    /// 打包拖出时手上是**一个 zip**，图像就该是 zip 的图标 ——
    /// 用第一个文件的图标会让人以为只拖走了那一个。
    private func zipDragImage() -> NSImage {
        let icon = NSWorkspace.shared.icon(for: .zip)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }

    private func contentType(for item: PerchItem) -> UTType {
        if let blobPath = item.blobPath,
           let type = UTType(filenameExtension: (blobPath as NSString).pathExtension) {
            return type
        }
        return item.kind == .image ? .png : .plainText
    }

    // MARK: - 文件名

    /// 用内容首行当文件名。
    ///
    /// 必须过滤 `/` 和 `:`：前者在 POSIX 层是路径分隔符，后者是访达显示层的分隔符，
    /// 带着它们建文件会失败或者被系统悄悄改名。
    static func sanitizedFilename(from raw: String, extension ext: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cleaned = firstLine
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: " ")
            // 再按空白切一次合并：连着两个非法字符会留下一串空格，文件名很难看。
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        // 逐字符截断而不是按字节：中文一个字 3 字节，按字节切会切出半个字。
        let base = cleaned.isEmpty ? "Perch" : String(cleaned.prefix(60))
        return "\(base).\(ext)"
    }
}

// MARK: - NSFilePromiseProviderDelegate

extension DragOutCoordinator: NSFilePromiseProviderDelegate {

    /// 主线程调用（头文件 `NS_SWIFT_UI_ACTOR`）。这里只报名字，不要开始写。
    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider as? FilePromiseProvider)?.promise.filename ?? "Perch.txt"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }

    /// 后台队列调用（头文件 `NS_SWIFT_NONISOLATED`），所以标 `nonisolated`。
    ///
    /// 两条铁律：
    /// 1. **必须用传进来的 `url`**，不能自己拼路径 —— 目标是沙盒 App 时，
    ///    这个 URL 是系统开好权限的临时位置，重名也已经由系统避让过了。
    /// 2. **必须调用 `completionHandler`**，成功失败都要调。不调的话目标 App
    ///    会一直转圈等我们，访达上表现为拷贝进度条卡死。
    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let provider = filePromiseProvider as? FilePromiseProvider else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }

        do {
            try provider.promise.write(url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

import AppKit
import UniformTypeIdentifiers

/// 统一调度两条拖出路径。
///
/// 策略（`pasteboardWriter(for:)`）：
/// - `blobs/` 里已经有本体的条目 → 写 `.fileURL`，让系统自己拷；
/// - 磁盘上还不存在的条目（文本、链接）→ 写 `FilePromiseProvider`，松手才生成。
///
/// 对外只暴露 `beginDrag(items:from:event:)`，多选拖出天然支持：
/// 一个 session 里放多个 `NSDraggingItem` 即可（M4 的批量拖出直接用）。
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
    func beginDrag(items: [PerchItem], from view: NSView & NSDraggingSource, event: NSEvent) {
        let origin = view.convert(event.locationInWindow, from: nil)

        let draggingItems: [NSDraggingItem] = items.compactMap { item in
            guard let writer = pasteboardWriter(for: item) else { return nil }

            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let image = dragImage(for: item)
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

    /// 条目本体在磁盘上真实存在时返回它的 URL。
    private func existingFileURL(for item: PerchItem) -> URL? {
        guard let blobPath = item.blobPath else { return nil }
        let url = BlobStore.absoluteURL(forRelativePath: blobPath)
        // 存在性必须真查一次：blobs/ 可能被用户手动清过，
        // 这时写一个指向空气的 .fileURL 出去，目标 App 只会收到一个报错弹窗。
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
                makeData: { Data(content.utf8) }
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
            let data = try provider.promise.makeData()
            try data.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

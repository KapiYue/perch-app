import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 把拖进来的东西变成架上的条目。
///
/// 类型判定优先级和 M2 的剪贴板监听保持一致：图片 > 文件URL > 链接 > 代码 > 纯文本。
/// 唯一的差别是拖入以**文件**为主，剪贴板以文本为主。
@MainActor
enum DropIngestor {

    static func canIngest(_ pasteboard: NSPasteboard) -> Bool {
        !fileURLs(in: pasteboard).isEmpty
            || imageData(in: pasteboard) != nil
            || pasteboard.string(forType: .string) != nil
    }

    @discardableResult
    static func ingest(_ pasteboard: NSPasteboard) -> Bool {
        let urls = fileURLs(in: pasteboard)
        if !urls.isEmpty {
            ingestFiles(urls)
            return true
        }

        if let data = imageData(in: pasteboard) {
            ingestImage(data)
            return true
        }

        if let text = pasteboard.string(forType: .string) {
            ingestText(text)
            return true
        }

        return false
    }

    // MARK: - 读 pasteboard

    /// 一次拖多个文件必须全部接收 —— `readObjects` 返回的就是全部，
    /// 不要用 `propertyList(forType: .fileURL)`（只给得到一个）。
    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    static func imageData(in pasteboard: NSPasteboard) -> Data? {
        pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }

    // MARK: - 落地
    //
    // 这三个入口拖入和剪贴板监听共用（`ClipboardWatcher`）。两边各写一份的话，
    // blobs/ 的落盘规则、缩略图生成、去重键格式会慢慢长歪成两套。

    static func ingestFiles(_ urls: [URL]) {
        // 拷贝放到后台：拖一个几百 MB 的视频进来，在主线程拷会把整个面板冻住。
        // 逐个拷、拷完一个上架一个，用户能看到进度，顺序也和拖入顺序一致。
        Task.detached(priority: .userInitiated) {
            for url in urls {
                do {
                    let item = try copyIntoBlobs(url)
                    await MainActor.run {
                        PerchStore.shared.add(item)
                        generateThumbnail(for: item, source: url)
                    }
                } catch {
                    NSLog("[Perch] 拖入失败 \(url.lastPathComponent)：\(error)")
                }
            }
        }
    }

    /// 把文件**拷贝**进 `blobs/<uuid>/`，不是只记原路径。
    ///
    /// 存引用的话，用户把原文件移走或删掉（这恰恰是「暂存中转」最常见的下一步），
    /// 架上的条目就成了死链接。拷贝的代价是占磁盘，由 M3 的自动清理负责收。
    private nonisolated static func copyIntoBlobs(_ source: URL) throws -> PerchItem {
        let id = UUID()
        let directory = BlobStore.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = source.lastPathComponent
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(filename))

        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        // 去重键 = 文件名 + 字节数 + 源文件修改时间，不做内容哈希（哈希一个几百 MB 的视频
        // 只为了判重不划算）。
        //
        // 🚨 修改时间这一项是必须的。只用「文件名 + 字节数」的话，
        // 两个同名同大小但**内容不同**的文件会被判成同一条（`report.pdf` 这种名字太常见了），
        // 结果是新拖进来的那份被丢掉、架上留着旧的 —— 用户再拖出去就是错的文件。
        // 加上修改时间之后，「同一个文件拖两次」照样命中去重，撞车则几乎不可能。
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return PerchItem(
            id: id,
            kind: .file,
            preview: filename,
            blobPath: "\(id.uuidString)/\(filename)",
            byteSize: Int64(size),
            dedupKey: "\(filename)|\(size)|\(Int(modified))"
        )
    }

    static func ingestImage(_ data: Data) {
        let id = UUID()
        do {
            let path = try BlobStore.write(data, filename: "content.png", for: id)
            let size = Formatters.size(Int64(data.count))
            PerchStore.shared.add(
                PerchItem(
                    id: id,
                    kind: .image,
                    preview: String(format: String(localized: "item.image.preview"), size),
                    blobPath: path,
                    byteSize: Int64(data.count),
                    dedupKey: "image|\(data.count)"
                )
            )
            generateImageThumbnail(from: data, for: id)
        } catch {
            NSLog("[Perch] 图片落地失败：\(error)")
        }
    }

    static func ingestText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 链接判定就看前缀，不做 URL 解析 —— 「www.」开头、中文域名这些边界情况
        // 判错的代价只是图标和颜色不同，不值得为它引入一套解析。
        let isLink = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")

        // 🚨 代码判定必须排在链接**之后**：`https://…` 在代码片段里很常见，
        // 反过来的话一行 URL 会被当成代码。
        // 认不出语言就退回 `.text`，不做「无语言的代码」（见 CodeDetector）。
        let language = isLink ? nil : CodeDetector.detect(trimmed)

        let kind: ItemKind = isLink ? .link : (language == nil ? .text : .code)

        PerchStore.shared.add(
            PerchItem(
                kind: kind,
                preview: trimmed,
                language: language,
                byteSize: Int64(trimmed.utf8.count),
                dedupKey: trimmed
            )
        )
    }

    // MARK: - 缩略图

    /// 剪贴板图片的缩略图。
    ///
    /// 走 ImageIO 而不是 `QLThumbnailGenerator`：后者要一个源**文件**，
    /// 而这里手上只有一段 Data。顺带 ImageIO 这条路是线程安全的，可以整段放后台。
    ///
    /// 不做的话列表里那个 26pt 的格子会去解原图 —— 一张截图三五 MB，滚起来立刻发涩。
    private static func generateImageThumbnail(from data: Data, for id: UUID) {
        Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                      source,
                      0,
                      [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 128,
                      ] as CFDictionary
                  )
            else { return }

            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                buffer,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return }

            CGImageDestinationAddImage(
                destination,
                thumbnail,
                [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return }

            let jpeg = buffer as Data
            await MainActor.run {
                guard let path = try? BlobStore.write(
                    jpeg,
                    filename: BlobStore.thumbnailFilename,
                    for: id
                ) else { return }
                PerchStore.shared.setThumbnail(path, for: id)
            }
        }
    }

    /// 生成失败不是错误：文件夹、未知类型本来就没有缩略图，
    /// 界面回退到系统图标即可，不要给用户报错。
    private static func generateThumbnail(for item: PerchItem, source: URL) {
        let request = QLThumbnailGenerator.Request(
            fileAt: source,
            size: CGSize(width: 128, height: 128),
            scale: 2,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            else { return }

            Task { @MainActor in
                guard let path = try? BlobStore.write(
                    jpeg,
                    filename: BlobStore.thumbnailFilename,
                    for: item.id
                ) else { return }
                PerchStore.shared.setThumbnail(path, for: item.id)
            }
        }
    }
}

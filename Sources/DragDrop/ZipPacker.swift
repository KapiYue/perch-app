import Foundation

/// 把架上的若干文件打包成一个 zip。
///
/// 用 `NSFileCoordinator` 的 `.forUploading`，不引第三方库 —— 这是访达右键「压缩」
/// 走的同一条路，产出的 zip 在任何解压工具下都正常。
///
/// 🚨 **必须先搭一个文件夹再压，不能直接压单个文件。**
/// 实测（2026-08-24）：`.forUploading` 对**目录**才产出 zip，对一个普通文件
/// 它只是返回一份原样的拷贝 —— 压出来的「zip」其实是那个文件本身，
/// 后缀写成 .zip 也解不开。所以哪怕只选了一个文件，这里也照样先建目录。
enum ZipPacker {

    enum Failure: Error {
        /// 协调器根本没调用回调（磁盘满、文件被独占等），`error` 是它给的原因。
        case coordinationFailed(Error?)
        case noSources
    }

    /// 打包 `sources` 到 `destination`。
    ///
    /// - Parameters:
    ///   - archiveName: zip 里那一层文件夹的名字。解压出来是一个文件夹而不是散落一地的文件，
    ///     和访达多选压缩的结果一致。
    ///   - destination: 落点，父目录必须已存在；同名文件会被覆盖。
    ///
    /// 整段是 `nonisolated` 的：调用方要么在拖出的后台写盘队列上，要么在导出的后台任务里，
    /// 主线程压一个几百 MB 的目录会把面板和菜单栏一起冻住。
    nonisolated static func pack(_ sources: [URL], archiveName: String, to destination: URL) throws {
        guard !sources.isEmpty else { throw Failure.noSources }

        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("perch-zip-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(archiveName, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        var used = Set<String>()
        for source in sources {
            // 同名文件要错开，否则第二个会覆盖第一个 —— 用户选了 3 个，zip 里只有 2 个，
            // 而这件事在拖到桌面解压之前完全看不出来。
            let name = uniqueName(source.lastPathComponent, taken: &used)
            let target = folder.appendingPathComponent(name)
            // 先硬链接：临时目录和 blobs/ 在同一个卷上，链接是常数时间、不占额外空间。
            // 一个 500MB 的视频走拷贝的话，压之前先白白多写 500MB。
            // 跨卷或文件系统不支持时退回拷贝。
            if (try? manager.linkItem(at: source, to: target)) == nil {
                try manager.copyItem(at: source, to: target)
            }
        }

        var coordinatorError: NSError?
        var moveError: Error?
        var produced = false

        NSFileCoordinator().coordinate(
            readingItemAt: folder,
            options: [.forUploading],
            error: &coordinatorError
        ) { zipURL in
            produced = true
            do {
                // 🚨 必须在这个闭包**里面**把 zip 搬走：回调一返回，协调器就把它删了。
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.moveItem(at: zipURL, to: destination)
            } catch {
                // 跨卷 move 会失败（落点可能在别的磁盘上），退回拷贝。
                do {
                    try manager.copyItem(at: zipURL, to: destination)
                } catch {
                    moveError = error
                }
            }
        }

        if let moveError { throw moveError }
        guard produced else { throw Failure.coordinationFailed(coordinatorError) }
    }

    /// zip 里那层文件夹的名字：单个文件用它自己的主名，多个文件由调用方给一个本地化的名字。
    ///
    /// 非法字符要过滤，理由和 `DragOutCoordinator.sanitizedFilename` 一样：
    /// `/` 是路径分隔符，`:` 是访达显示层的分隔符，带着它们建目录会失败或被系统悄悄改名。
    nonisolated static func sanitized(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return cleaned.isEmpty ? "Perch" : String(cleaned.prefix(60))
    }

    // MARK: - 重名

    private nonisolated static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        guard taken.contains(name) else {
            taken.insert(name)
            return name
        }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !taken.contains(candidate) {
                taken.insert(candidate)
                return candidate
            }
            index += 1
        }
    }
}

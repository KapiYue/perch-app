import AppKit

/// 文件区那些「把东西送出栖架」的动作：打开 / 在访达中显示 / 导出 / 打包 ZIP / AirDrop。
///
/// 集中一处的理由和 `Formatters` 一样：批量操作条、右键菜单、双击**共用同一批动作**，
/// 各写一份的话「导出之后要不要收面板」这类问题会在三个地方给出三种答案。
///
/// 🚨 所有会把用户送去别的 App 的动作，做完都要 `collapseAfterHandoff()`。
/// 面板是 `.statusBar` 层级，盖在所有普通窗口之上 —— 打开一个 PDF 却发现
/// 预览窗口被面板压着一条，用户只会以为哪里卡住了。
@MainActor
enum FileActions {

    // MARK: - 打开 / 定位

    /// 双击，或右键「打开」。用系统默认应用打开 `blobs/` 里的那份副本。
    ///
    /// ⚠️ 打开的是**副本**，不是用户当初拖进来的原文件。在里面改了东西，改的也是副本，
    /// 而且它照样受保存时长管辖、到点会被清掉。这是「暂存中转」的应有之义
    /// （拖进来的那一刻就已经是拷贝了，见 `DropIngestor.copyIntoBlobs`），
    /// 不要为了「改动能存住」把它改成打开原路径 —— 原文件很可能已经被用户删了。
    static func open(_ items: [PerchItem]) {
        let urls = DragOutCoordinator.shared.existingFileURLs(for: items)
        guard !urls.isEmpty else { return }

        PanelController.shared.collapseAfterHandoff()
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    /// 在访达里选中这些文件。
    static func revealInFinder(_ items: [PerchItem]) {
        let urls = DragOutCoordinator.shared.existingFileURLs(for: items)
        guard !urls.isEmpty else { return }

        PanelController.shared.collapseAfterHandoff()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - 复制路径 / 重命名

    /// 复制这些文件的绝对路径（多条用换行分隔）。
    ///
    /// ⚠️ 复制出来的是 `blobs/<uuid>/` 里那份副本的路径，**它会被自动清理带走**。
    /// 这条路径的用途是「粘到终端里马上用一下」，不是「记在某个配置文件里长期引用」。
    static func copyPaths(_ items: [PerchItem]) {
        let urls = DragOutCoordinator.shared.existingFileURLs(for: items)
        guard !urls.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        // 🚨 我们自己写的这一次不能被监听当成新内容抓回来 ——
        // 否则「复制路径」会立刻在剪贴板区多出一条路径文本，架上越用越脏。
        ClipboardWatcher.shared.acknowledgeSelfWrite()

        // 和单击取回同一个口径：复制完就走。
        PanelController.shared.collapseAfterHandoff()
    }

    /// 改名。**只对单个条目**开放。
    ///
    /// 用 `NSAlert` + 一个输入框，而不是在面板里做行内编辑：面板 `canBecomeKey = false`，
    /// 里面放任何输入控件都收不到键盘。弹窗是独立窗口，能正常拿焦点。
    static func rename(_ item: PerchItem) {
        NSApp.activate(ignoringOtherApps: true)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = item.preview

        let alert = NSAlert()
        alert.messageText = String(localized: "files.rename.title")
        alert.informativeText = String(localized: "files.rename.detail")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "files.rename.confirm"))
        alert.addButton(withTitle: String(localized: "alert.cancel"))
        // 弹出来光标就在输入框里，不用先点一下。
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 非法字符按和文件名同一套规则过滤（`/` 是路径分隔符，`:` 是访达的分隔符）。
        let newName = ZipPacker.sanitized(field.stringValue)
        guard newName != item.preview else { return }

        do {
            try PerchStore.shared.renameFile(item.id, to: newName)
        } catch {
            // 最常见的失败是重名（同目录下还有缩略图 thumb.jpg）。必须说话，
            // 不然用户会以为改成功了，直到拖出去才发现名字没变。
            presentFailure(error)
        }
    }

    // MARK: - 导出

    /// 导出到「下载」文件夹，完成后在访达里选中它们。
    ///
    /// 为什么是「下载」而不是弹一个保存面板：`NSSavePanel` 要求 App 是活跃的，
    /// 而面板 `canBecomeKey = false`、栖架永远不是前台 App —— 弹出来的面板会既拿不到
    /// 键盘也拿不到焦点。想选位置的用户有更好的办法：直接把格子拖到那个位置去。
    /// 点按这条路径要的就是「别问我，放个我一定找得到的地方」。
    ///
    /// 完成后跳访达是必须的：不跳的话这个动作在界面上**没有任何反馈**，
    /// 用户不知道东西去哪儿了，只能自己翻。
    static func exportToDownloads(_ items: [PerchItem]) {
        let urls = DragOutCoordinator.shared.existingFileURLs(for: items)
        guard !urls.isEmpty, let downloads = downloadsDirectory else { return }

        PanelController.shared.collapseAfterHandoff()

        Task.detached(priority: .userInitiated) {
            do {
                var landed: [URL] = []
                for url in urls {
                    let destination = uniqueDestination(url.lastPathComponent, in: downloads)
                    try FileManager.default.copyItem(at: url, to: destination)
                    landed.append(destination)
                }
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(landed) }
            } catch {
                await MainActor.run { presentFailure(error) }
            }
        }
    }

    /// 打包成一个 zip 放到「下载」文件夹，完成后在访达里选中它。
    ///
    /// 和「拖出去打包」是同一个 `ZipPacker`，区别只在落点：
    /// 拖是用户指定位置、松手才压；点是压到「下载」。
    static func exportZipToDownloads(_ items: [PerchItem]) {
        let urls = DragOutCoordinator.shared.existingFileURLs(for: items)
        guard !urls.isEmpty, let downloads = downloadsDirectory else { return }

        let name = DragOutCoordinator.zipName(for: items)
        PanelController.shared.collapseAfterHandoff()

        Task.detached(priority: .userInitiated) {
            do {
                let destination = uniqueDestination("\(name).zip", in: downloads)
                try ZipPacker.pack(urls, archiveName: name, to: destination)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } catch {
                await MainActor.run { presentFailure(error) }
            }
        }
    }

    // MARK: - AirDrop

    /// 通过 AirDrop 发出去。
    ///
    /// 用 `NSSharingService(named: .sendViaAirDrop)` 直接发，而不是 `NSSharingServicePicker`：
    /// picker 是挂在一个视图上的浮层，而面板永远不是 key 窗口，浮层能画出来但拿不到键盘。
    /// AirDrop 服务自己会开一个系统窗口，不受这条限制。
    ///
    /// 🚨 这里**必须**先 `activate` —— AirDrop 的窗口属于栖架，
    /// 不激活的话它会开在当前前台 App 的后面，用户看到的是「点了没反应」。
    /// 这是整个项目里唯一一处主动抢焦点的地方：面板自动弹出时绝对不能这么做，
    /// 但「用户点了分享」是明确的意图，弹出来的东西本来就该在最前面。
    static func sendViaAirDrop(_ items: [PerchItem]) {
        let urls = DragOutCoordinator.shared.existingFileURLs(for: items)
        guard !urls.isEmpty else { return }

        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls)
        else {
            presentMessage(
                title: String(localized: "files.airdrop.unavailable.title"),
                detail: String(localized: "files.airdrop.unavailable.detail")
            )
            return
        }

        PanelController.shared.collapseAfterHandoff()
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    // MARK: - 右键菜单

    /// 弹出右键菜单，并在菜单开着期间按住面板不让它收。
    ///
    /// `popUp` 会**接管事件循环**直到菜单关掉，所以下一行就是「菜单已经关了」。
    static func showContextMenu(for items: [PerchItem], event: NSEvent, in view: NSView) {
        guard !items.isEmpty else { return }

        PanelController.shared.contextMenuWillOpen()
        let menu = contextMenu(for: items)
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        PanelController.shared.contextMenuDidClose()
    }

    private static func contextMenu(for items: [PerchItem]) -> NSMenu {
        let menu = NSMenu()
        // 我们自己给每一项设了 target/action，不需要 AppKit 再去响应链上问一遍
        // ——面板不是 key 窗口，那条路径上问不到人，问了反而会把整份菜单变灰。
        menu.autoenablesItems = false

        let suffix = items.count > 1
            ? String(format: String(localized: "files.menu.count.suffix"), items.count)
            : ""

        func add(_ titleKey: String.LocalizationValue, _ symbol: String, _ action: @escaping @MainActor () -> Void) {
            menu.addItem(
                ActionMenuItem(title: String(localized: titleKey) + suffix, symbol: symbol, handler: action)
            )
        }

        add("files.menu.open", "arrow.up.forward.app") { open(items) }
        add("files.menu.reveal", "folder") { revealInFinder(items) }
        menu.addItem(.separator())
        add("files.menu.copyPath", "doc.on.doc") { copyPaths(items) }
        // 改名只对单条开放：多选时「批量改成同一个名字」没有意义，
        // 而访达那种「加序号批量重命名」是另一个功能，1.0 不做。
        if items.count == 1, let only = items.first {
            menu.addItem(
                ActionMenuItem(
                    title: String(localized: "files.menu.rename"),
                    symbol: "pencil",
                    handler: { rename(only) }
                )
            )
        }
        menu.addItem(.separator())
        add("files.menu.export", "arrow.down.circle") { exportToDownloads(items) }
        add("files.menu.zip", "doc.zipper") { exportZipToDownloads(items) }
        add("files.menu.airdrop", "wifi") { sendViaAirDrop(items) }
        menu.addItem(.separator())

        let allPinned = items.allSatisfy(\.isPinned)
        add(allPinned ? "files.action.unpin" : "files.action.pin", allPinned ? "star.slash" : "star") {
            setPinned(!allPinned, on: items)
        }
        add("files.action.remove", "xmark") { remove(items) }

        return menu
    }

    // MARK: - 固定 / 移除

    static func setPinned(_ pinned: Bool, on items: [PerchItem]) {
        // 复用 store 的批量口径（「全都固定了才取消」），所以先把选中集摆成这一批。
        let store = PerchStore.shared
        store.selectedFileIDs = Set(items.map(\.id))
        if store.selectedFilesAllPinned != pinned {
            store.toggleSelectedFilesPin()
        }
    }

    static func remove(_ items: [PerchItem]) {
        let store = PerchStore.shared
        store.selectedFileIDs = Set(items.map(\.id))
        store.removeSelectedFiles()
    }

    // MARK: - 落点与报错

    private static var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// 「下载」里已经有同名文件时错开，不覆盖。
    ///
    /// 覆盖是不可接受的：架上那份 `report.pdf` 和用户「下载」里那份很可能毫无关系，
    /// 而导出这个动作在用户眼里只是「存一份出来」，没有任何理由删掉别的东西。
    private nonisolated static func uniqueDestination(_ filename: String, in directory: URL) -> URL {
        let manager = FileManager.default
        var candidate = directory.appendingPathComponent(filename)
        guard manager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        repeat {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        } while manager.fileExists(atPath: candidate.path)

        return candidate
    }

    /// 导出失败必须说话。
    ///
    /// 这条路径没有「行内反馈」可用（面板已经收走了），而**静默失败是这个项目最不能接受的
    /// 失败方式** —— 用户会去「下载」里找一个根本不存在的文件。
    private static func presentFailure(_ error: Error) {
        NSLog("[Perch] 导出失败：\(error)")
        presentMessage(
            title: String(localized: "files.export.failed.title"),
            detail: error.localizedDescription
        )
    }

    private static func presentMessage(title: String, detail: String) {
        // 弹窗要在最前面才有意义，而栖架平时不是前台 App。
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "alert.ok"))
        alert.runModal()
    }
}

/// 只为了把一个闭包挂到菜单项上。
///
/// AppKit 的菜单项走的是 target/action，没有闭包出口；而这里每一项要做的事
/// 都依赖「右键点的是哪几条」，做不成一组固定的 selector。
@MainActor
private final class ActionMenuItem: NSMenuItem {

    private let handler: @MainActor () -> Void

    init(title: String, symbol: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) {
        fatalError("菜单是代码建的，不会从 xib 里解出来")
    }

    /// 🚨 推到下一轮 runloop 再做事。
    ///
    /// action 是在**菜单的事件循环里**被调用的，此刻菜单还没真正收场。
    /// 在这里直接弹 `NSAlert`、开 AirDrop 窗口或者收面板，等于在一个正在退栈的
    /// 事件循环里再嵌一层，轻则动画卡一下，重则弹窗压在菜单残影底下。
    @objc private func fire() {
        let handler = handler
        DispatchQueue.main.async { handler() }
    }
}

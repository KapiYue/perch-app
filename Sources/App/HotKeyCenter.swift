import AppKit
import Carbon.HIToolbox

/// 四字符签名 `'PERC'`。同一个进程里可能有别的库也在注册热键，
/// 靠它区分哪些回调是我们的。
///
/// 放在文件级而不是类型里：Carbon 回调是 nonisolated 的，
/// 而 `@MainActor` 类型的静态成员同样带 MainActor 隔离，在回调里读不到。
private let perchHotKeySignature: OSType = 0x5045_5243

/// 全局热键：**⌃⌘V 唤出/收起面板**（常驻），以及只在面板展开期间生效的三个：
/// ⌘1–⌘9「取第 N 条」、⌘A「全选文件」、Esc「取消选中」。
///
/// ## 为什么用 Carbon 的 `RegisterEventHotKey`
///
/// 面板 `canBecomeKey = false`（不能抢焦点，否则前台 App 的输入光标会消失），
/// 所以键盘事件**根本不会走到我们的窗口**，`addLocalMonitorForEvents` 收不到。
/// 剩下两条路：
/// - `addGlobalMonitorForEvents`：要「辅助功能」授权，而且**只能旁观、吞不掉事件** ——
///   按 ⌘1 会变成「浏览器切了标签页 + 栖架也复制了一条」，两件事同时发生。
/// - `RegisterEventHotKey`：不需要任何授权，而且能真正吃掉这个组合键。
///
/// ## 🔴 为什么只在面板展开时注册
///
/// 主文档写的是「全局快捷键，面板收起时也生效」。**没有照做**，原因是
/// ⌘1–⌘9 在浏览器是切标签页、在访达是切视图、在一堆 App 里都有绑定 ——
/// 常驻注册等于把这九个组合键从**所有** App 手里抢走。
///
/// 现在的口径：面板展开时这九个键归栖架，收起时立刻还回去。冲突窗口只存在于
/// 「用户正盯着面板」的那几秒，而那几秒里他本来也不会去切标签页。
@MainActor
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    /// ⌘1–⌘9 对应的虚拟键码。**不是连续的** —— 6 和 5 在这张表里是反的，
    /// 照着数字顺序 +1 推会错位。
    private static let numberKeyCodes: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
        kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
        kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    /// 唤出键的热键 id。1–9 留给数字键，所以从 100 起。
    private static let toggleKeyID: UInt32 = 100
    private static let selectAllKeyID: UInt32 = 101
    private static let escapeKeyID: UInt32 = 102

    private var hotKeys: [EventHotKeyRef] = []
    private var toggleKey: EventHotKeyRef?
    private var selectAllKey: EventHotKeyRef?
    private var escapeKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private init() {}

    var isRegistered: Bool { !hotKeys.isEmpty }

    /// **⌃⌘V：唤出 / 收起面板。** 常驻注册，启动时挂上。
    ///
    /// 为什么不是主文档原本写的 ⌘⇧V：那是一大批 App 的「粘贴并匹配样式」，
    /// 常驻注册等于把它从所有 App 手里抢走。⌃⌘V 上没有系统绑定，V 的记忆点也还在。
    ///
    /// 键盘流程是闭合的：⌃⌘V 唤出 → ⌘1–⌘9 取第 N 条（面板一展开就注册了）
    /// → 取完 1.1 秒自动收起。全程手不离键盘，也不需要鼠标悬停。
    /// 唤出后不想取了，再按一次 ⌃⌘V 收起 —— 面板不抢焦点，收不到 Esc。
    func registerToggleKey() {
        guard toggleKey == nil else { return }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: perchHotKeySignature, id: Self.toggleKeyID)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | cmdKey),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            toggleKey = ref
        } else {
            // 被别的 App 抢先占了。菜单栏图标和顶部黑条这两个入口还在，不致命。
            NSLog("[Perch] ⌃⌘V 注册失败（OSStatus \(status)），可能已被其它 App 占用")
        }
    }

    /// 面板展开时调用。
    func registerNumberKeys() {
        guard hotKeys.isEmpty else { return }
        installHandlerIfNeeded()

        for (offset, keyCode) in Self.numberKeyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: perchHotKeySignature, id: UInt32(offset + 1))
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(cmdKey),
                id,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            // 别的 App 已经全局占了同一个组合键时会失败。失败就跳过这一个，
            // 不影响其余八个 —— 这不是错误，不要弹窗打扰用户。
            if status == noErr, let ref {
                hotKeys.append(ref)
            }
        }
    }

    /// 面板收起时调用，把键还给别的 App。
    func unregisterNumberKeys() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }

    // MARK: - 文件区的 ⌘A / Esc

    /// 文件区多选用的两个键。面板展开期间调用，条目或选中态一变就再调一次。
    ///
    /// 🔴 **两个键各有各的前提，不是「展开就一起注册」**，因为它们抢走的东西不一样：
    /// - `⌘A` 只在**架上真的有文件**时注册。空文件区注册它，等于白白从前台 App
    ///   手里抢走「全选」；
    /// - `Esc` 只在**真的有选中项**时注册。Esc 是裸键（没有修饰键），
    ///   抢走它的代价比 ⌘A 大得多 —— 前台 App 的对话框取消、退出全屏、输入法候选
    ///   全都指望它。所以窗口要压到最小：只有「面板开着 + 手里有选中项」这一小段时间。
    ///
    /// 收起面板走 `unregisterFileKeys()`，两个一起还回去。
    func syncFileKeys(hasFiles: Bool, hasSelection: Bool) {
        setKey(&selectAllKey, enabled: hasFiles, keyCode: kVK_ANSI_A, modifiers: cmdKey, id: Self.selectAllKeyID)
        setKey(&escapeKey, enabled: hasSelection, keyCode: kVK_Escape, modifiers: 0, id: Self.escapeKeyID)
    }

    func unregisterFileKeys() {
        syncFileKeys(hasFiles: false, hasSelection: false)
    }

    /// 注册/注销一个热键，已经是目标状态就什么都不做。
    ///
    /// 幂等这一点是必须的：`syncFileKeys` 挂在 store 的变更通知上，
    /// 每复制一条内容都会走一遍，每次都反注册再注册的话，
    /// 用户按住 ⌘A 不放的那一刻正好撞上重注册，这一下就丢了。
    private func setKey(
        _ slot: inout EventHotKeyRef?,
        enabled: Bool,
        keyCode: Int,
        modifiers: Int,
        id: UInt32
    ) {
        if enabled {
            guard slot == nil else { return }
            installHandlerIfNeeded()

            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: perchHotKeySignature, id: id)
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            // 被别人占了就算了，不弹窗 —— 鼠标那条路径照常可用。
            if status == noErr { slot = ref }
        } else {
            guard let ref = slot else { return }
            UnregisterEventHotKey(ref)
            slot = nil
        }
    }

    /// 热键按下。
    ///
    /// ⌘N 走到这里时面板一定是展开的（只有展开才注册），所以行内反馈看得见，
    /// 不需要主文档 2.4 里那条「面板收起时退回轻量提示」的例外。
    fileprivate func handle(hotKeyID id: UInt32) {
        switch id {
        case Self.toggleKeyID:
            PanelController.shared.toggle()
            return
        case Self.selectAllKeyID:
            PerchStore.shared.selectAllFiles()
            return
        case Self.escapeKeyID:
            PerchStore.shared.clearSelection()
            return
        default:
            break
        }

        // 1–9 转成从 0 开始的下标。
        guard let item = PerchStore.shared.clipboardItem(at: Int(id) - 1) else { return }
        ClipboardTaker.shared.take(item)
    }

    // MARK: - Carbon 事件处理

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &handler)
    }
}

/// Carbon 的回调是 C 函数指针，**不能捕获上下文**，所以只能是文件级函数。
///
/// 回调本身在主线程被调用，但 Swift 6 严格并发下这里是 nonisolated 的，
/// 碰不到 `@MainActor` 的单例，只能再跳一次主队列。
private func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr, id.signature == perchHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let hotKeyID = id.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotKeyCenter.shared.handle(hotKeyID: hotKeyID) }
    }
    return noErr
}

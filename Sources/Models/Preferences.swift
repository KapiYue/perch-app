import Foundation

/// 开关类小状态（UserDefaults）。
///
/// 条目本身走 `index.json`（`DiskStore`），**不要**把条目往这里塞 ——
/// UserDefaults 每次写都会整个 plist 重写，几百条历史放进去启动就卡了。
enum Preferences {

    /// 键名同时给 `@AppStorage` 用（设置窗口直接绑这些键，不再另存一份状态）。
    enum Key {
        static let monitoringPaused = "perch.monitoringPaused"
        static let retention = "perch.retention"
        static let autoExpandOnHover = "perch.autoExpandOnHover"
        static let excludedSourceApps = "perch.excludedSourceApps"
    }

    /// 剪贴板监听是否已暂停。面板头部的 ⏸ 按钮绑定它，跨重启保留。
    static var isMonitoringPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Key.monitoringPaused) }
        set { UserDefaults.standard.set(newValue, forKey: Key.monitoringPaused) }
    }

    /// 保存时长，默认 12 小时。
    ///
    /// 存 rawValue 而不是小时数：`never` 没有对应的小时数，
    /// 用 0 或 -1 去表示它，早晚会有一处忘了判而把「永不」算成「立刻过期」。
    static var retention: Janitor.Retention {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.retention),
                  let value = Janitor.Retention(rawValue: raw)
            else { return .default }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.retention) }
    }

    /// 悬停自动展开。**默认开**，关掉之后只能靠单击黑条 / ⌃⌘V / 菜单栏唤出。
    ///
    /// `bool(forKey:)` 对没写过的键返回 false，直接用它会把默认值变成「关」，
    /// 所以这里要先看键在不在。
    static var autoExpandOnHover: Bool {
        get { UserDefaults.standard.object(forKey: Key.autoExpandOnHover) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoExpandOnHover) }
    }

    // 🔴 「跳过被标记为机密的内容」那个开关已经拿掉了（2026-08-25）：
    // 标记改成永远生效，见 `ClipboardWatcher.skipMarkerTypes`。
    // 老版本写下的 `perch.skipConcealedContent` 键留在 UserDefaults 里没人读，无害，
    // 不专门去清 —— 清它要多一段只跑一次的迁移代码，代价比留着大。

    // MARK: - 按来源 App 忽略

    /// 默认忽略的来源 App。
    ///
    /// 🔴 **为什么需要这条，以及为什么它不违反「不做密码识别」**：
    /// 2026-08-25 实测（macOS 26.5.1），macOS 自带的「密码」App 放到剪贴板上的类型
    /// **只有一个 `public.utf8-plain-text`** —— 没有 `ConcealedType`，也没有任何 Apple 私有标记。
    /// 也就是说它复制出来的密码，和从记事本里复制一段文字，在栖架眼里是完全一样的一段纯文本。
    /// 靠标记那条路（`skipConcealedContent`）永远覆盖不到它。
    ///
    /// 这条规则判的是**「谁给的」，不是「内容像什么」** —— 一个字节的内容都不看，
    /// 所以它不是启发式识别，那条产品决定依然成立。
    ///
    /// **默认是开的**（预置这两条）。与「跳过机密内容」默认关闭不同，
    /// 那条的可靠性取决于来源 App 配不配合，所以只能让用户自己决定要不要信；
    /// 而这条是确定性的：点名了就一定跳过。明知道自带「密码」会被原样记下来还默认不管，
    /// 说不过去。用户想要这份历史的话，在设置里把它移掉就行 —— 名单是看得见的。
    static let defaultExcludedSourceApps = [
        "com.apple.Passwords",      // 「密码」
        "com.apple.keychainaccess", // 「钥匙串访问」
    ]

    /// 这些 App 复制的内容不上架。空数组 = 这条规则关掉了。
    ///
    /// 键没写过时返回默认名单；写过（哪怕写的是空数组）就以用户的为准 ——
    /// 用 `object(forKey:)` 而不是 `stringArray(forKey:)` 才分得出「没配置过」和「配置成空」。
    static var excludedSourceApps: [String] {
        get { UserDefaults.standard.object(forKey: Key.excludedSourceApps) as? [String]
                ?? defaultExcludedSourceApps }
        set { UserDefaults.standard.set(newValue, forKey: Key.excludedSourceApps) }
    }

    /// 这次复制的来源 App 要不要忽略。
    ///
    /// 认不出来源（`bundleIdentifier` 为 nil）时**不忽略** —— 宁可多记一条，
    /// 也不要因为一次识别失败就把用户真正想留的内容悄悄吞掉。
    ///
    /// 大小写不敏感：bundle id 在 macOS 上按不区分大小写处理，
    /// 用户手敲一个 `com.apple.passwords` 进名单不该失效。
    static func isExcludedSource(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return excludedSourceApps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

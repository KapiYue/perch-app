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
        static let skipConcealedContent = "perch.skipConcealedContent"
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

    /// 跳过来源 App 标记为机密的剪贴板内容（`org.nspasteboard.ConcealedType`）。
    ///
    /// **默认关闭**，官网隐私页和两份 README 都是这么写的，不要改默认值。
    /// 这不是「猜内容是不是密码」（那条产品决定是明确不做），
    /// 而是尊重来源 App 自己打的标记，可靠性取决于来源 App 规不规范。
    static var skipConcealedContent: Bool {
        get { UserDefaults.standard.bool(forKey: Key.skipConcealedContent) }
        set { UserDefaults.standard.set(newValue, forKey: Key.skipConcealedContent) }
    }
}

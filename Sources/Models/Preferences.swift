import Foundation

/// 开关类小状态（UserDefaults）。
///
/// 条目本身走 `index.json`（M3），**不要**把条目往这里塞 ——
/// UserDefaults 每次写都会整个 plist 重写，几百条历史放进去启动就卡了。
enum Preferences {

    private enum Key {
        static let monitoringPaused = "perch.monitoringPaused"
        static let retentionHours = "perch.retentionHours"
    }

    /// 剪贴板监听是否已暂停。面板头部的 ⏸ 按钮绑定它，跨重启保留。
    static var isMonitoringPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Key.monitoringPaused) }
        set { UserDefaults.standard.set(newValue, forKey: Key.monitoringPaused) }
    }

    /// 保存时长，默认 12 小时。设置项 UI 和真正的清理都在 M3，
    /// M2 只用它算「多久后清理」这行字。
    static var retentionHours: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Key.retentionHours)
            return stored > 0 ? stored : 12
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.retentionHours) }
    }

    static var retentionInterval: TimeInterval { TimeInterval(retentionHours) * 3600 }
}

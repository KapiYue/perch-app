import Foundation

/// 过期清理。
///
/// 规则很短，但每一条都是硬性的：
/// - 保存时长是**唯一**的自动清理依据，没有其他触发条件；
/// - 从 `retentionAnchor` 起算（= 上架时间，去重命中或取消固定时重置）；
/// - `isPinned == true` 的条目永不过期；
/// - 清理条目时必须**同步删除 blobs/ 下对应目录**，不留孤儿。
enum Janitor {

    /// 可选的保存时长。默认 12 小时。
    enum Retention: String, Codable, CaseIterable, Sendable {
        case oneHour
        case twelveHours
        case oneDay
        case sevenDays
        case never

        static let `default`: Retention = .twelveHours

        /// 返回 nil 表示永不过期。
        var timeInterval: TimeInterval? {
            switch self {
            case .oneHour:     return 60 * 60
            case .twelveHours: return 12 * 60 * 60
            case .oneDay:      return 24 * 60 * 60
            case .sevenDays:   return 7 * 24 * 60 * 60
            case .never:       return nil
            }
        }

        var titleKey: String { "settings.retention.\(rawValue)" }
    }

    /// 扫描间隔：启动时一次 + 每 60 秒一次。
    static let scanInterval: TimeInterval = 60

    /// 剪贴板区条数上限，超出丢弃最旧的（固定项不计入淘汰）。
    static let clipboardLimit = 200

    // MARK: - 定时扫描

    @MainActor private static var timer: Timer?

    /// 挂上定时扫描。启动时调一次，内部自己防重入。
    ///
    /// **「启动时那一次」不在这里** —— 在 `PerchStore.adopt` 里，读盘读完的那一刻。
    /// 放这儿是没用的：这个方法跑的时候历史还没读回来，扫的是一个空列表。
    @MainActor
    static func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: scanInterval, repeats: true) { _ in
            MainActor.assumeIsolated { PerchStore.shared.sweepExpired() }
        }
        // 和 `ClipboardWatcher` 同样的理由：默认模式在菜单弹开、拖拽期间整个停摆。
        // 清理晚一分钟无伤大雅，但「面板开着的时候定时器全停」不是我们想要的语义。
        RunLoop.main.add(timer, forMode: .common)
        Self.timer = timer
    }

    @MainActor
    static func stop() {
        timer?.invalidate()
        timer = nil
    }
}

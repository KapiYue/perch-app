import Foundation

/// 过期清理。
///
/// M3 实现。规则很短，但每一条都是硬性的：
/// - 保存时长是**唯一**的自动清理依据，没有其他触发条件；
/// - 从 `createdAt` 起算，去重命中会重置计时；
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
    }

    /// 扫描间隔：启动时一次 + 每 60 秒一次。
    static let scanInterval: TimeInterval = 60

    /// 剪贴板区条数上限，超出丢弃最旧的（固定项不计入淘汰）。
    static let clipboardLimit = 200
}

import Foundation

/// 面板与设置页共用的几个 formatter。
///
/// 集中放一处的理由很实际：体积、"多久前"、"多久后清理" 这三样在
/// 面板头部 / 剪贴板行 / 文件格子 / 设置页都要用，各写各的话，
/// 同一个数字会在四个地方长成四种样子。
///
/// 标 `@MainActor` 是因为 formatter 都不是 Sendable，而这几个调用点全在主线程。
/// 用 static let 缓存起来 —— formatter 的初始化不轻，而这些属性每次重绘都会被读。
@MainActor
enum Formatters {

    /// 体积。
    ///
    /// 🚨 `allowsNonnumericFormatting` 必须关掉。默认是开的，0 字节会被格式化成
    /// 「Zero KB」（中文「零字节」）—— 夹在「剪贴板 0 · 文件 0 · Zero KB」里读着像是出错了，
    /// 而这恰恰是空架子时最常见的那一行。关掉之后是老老实实的「0 字节 / 0 bytes」。
    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func size(_ byteCount: Int64) -> String {
        bytes.string(fromByteCount: byteCount)
    }

    /// 「3 分钟前」。
    private static let elapsed: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // 刚上架的那一条差值几乎是 0，`.numeric` 会算成「0 秒前」；`.named` 给「现在」。
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// 🚨 参照点要夹一下。调用方的 `now` 通常是 30 秒才跳一次的，而条目是随时上架的：
    /// 上一次跳之后新增的那条 `createdAt > now`，直接算会显示成「1 秒**后**」。
    static func elapsed(since date: Date, now: Date) -> String {
        elapsed.localizedString(for: date, relativeTo: max(now, date))
    }

    /// 「11 小时」。
    private static let remaining: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        // 只留最大的那一档：「11 小时 34 分钟后清理」在 9.5pt 上就是一团糊。
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .short
        return formatter
    }()

    /// 距离被清理还剩多久。返回 nil = 不该显示倒计时
    /// （固定项、保存时长设成「永不」、或者已经到点了正等着下一次扫描）。
    static func remaining(for item: PerchItem, now: Date) -> String? {
        guard let expiry = item.expiryDate(under: PerchStore.shared.retention), expiry > now else {
            return nil
        }
        return remaining.string(from: now, to: expiry)
    }

    /// 行内 / 格内那句「X · Y后清理」。`leading` 是前半段（多久前，或者文件体积）。
    static func meta(_ leading: String, for item: PerchItem, now: Date) -> String {
        if item.isPinned {
            return "\(leading) · \(String(localized: "item.pinned"))"
        }
        guard let left = remaining(for: item, now: now) else { return leading }
        return String(format: String(localized: "item.meta.expires"), leading, left)
    }
}

import AppKit
import UniformTypeIdentifiers

/// 一次「拖出」承诺要落地的文件。
///
/// 必须是 `Sendable`，而且必须自包含：真正写盘发生在后台队列
/// （`NSFilePromiseProviderDelegate.filePromiseProvider(_:writePromiseTo:completionHandler:)`
/// 在头文件里标了 `NS_SWIFT_NONISOLATED`），那里**碰不到 `@MainActor` 的 `PerchStore`**。
/// 所以开拖那一刻就要把文件名、类型、以及「怎么产生内容」全部装进来。
struct PromisedFile: Sendable {

    /// 落地后的文件名，含扩展名。
    let filename: String

    /// 决定 provider 的 `fileType`。不符合 `public.data` / `public.directory` 会直接抛异常。
    let type: UTType

    /// 内容在**用户松手那一刻**才产生 —— 这正是用承诺而不是直接给文件的意义。
    let makeData: @Sendable () throws -> Data
}

/// 「拖出成真文件」的承诺提供者。
///
/// 🚨 这是整个项目技术难度最高、也是唯一「做不出来就废了」的能力，M1-a 先单独验证它。
///
/// 剪贴板里的一段文字在磁盘上并不是一个文件。`NSFilePromiseProvider` 的意义在于：
/// 把文件的**生成时机推迟到用户松手那一刻**，由 delegate 写到用户放下的位置。
///
/// 两条路径要分清（策略在 `DragOutCoordinator.pasteboardWriter(for:)`）：
/// - 已经存在于 `blobs/` 的文件 → 直接走 `.fileURL`，不需要承诺；
/// - 需要现生成的内容（文本、链接，以及 M4 的 ZIP 打包）→ 走本类。
///
/// 本类**不是** `@MainActor`：`NSFilePromiseProvider` 在 AppKit 头文件里没有标
/// `NS_SWIFT_UI_ACTOR`，而后台的写盘回调要读 `promise`，标了主线程就编译不过。
final class FilePromiseProvider: NSFilePromiseProvider {

    /// 只读、只含 Sendable 内容，所以跨线程读它是安全的。
    let promise: PromisedFile

    init(promise: PromisedFile, delegate: NSFilePromiseProviderDelegate) {
        self.promise = promise
        super.init()
        fileType = promise.type.identifier
        // ⚠️ `delegate` 在 AppKit 里是 **weak** 的。
        // 传一个临时对象进来，drop 的时候 delegate 已经没了 ——
        // 表现是：拖出去看着成功，但目标位置什么都没有，控制台也不报错。
        // 所以这里只接受 DragOutCoordinator.shared 这种长生命周期对象。
        self.delegate = delegate
    }
}

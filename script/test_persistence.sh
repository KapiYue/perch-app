#!/usr/bin/env bash
#
# 持久化 / 去重 / 淘汰 / 过期清理 的离线自测（M3）。
#
# 和 test_code_detector.sh 同样的理由：这一段是**纯数据逻辑**，不需要人肉真机操作。
# 拖拽、窗口层级、剪贴板得靠手验，但「去重命中要不要新增」「200 条满了先保住谁」
# 「取消固定之后倒计时从哪一刻起算」这些，用错了要过好几个小时才看得出来 ——
# 恰恰是最需要脚本盯着的部分。
#
# 编译的是 Sources/ 下的**本体**，不是拷贝 —— 拷一份出来做测试，
# 改了实现却忘了同步，脚本就会一直报绿。
#
#   用法：./script/test_persistence.sh
#   退出码：0 全过；1 有不符（可以直接进 CI）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCES=(
  Sources/Models/PerchItem.swift
  Sources/Models/PerchStore.swift
  Sources/Models/Preferences.swift
  Sources/Storage/BlobStore.swift
  Sources/Storage/DiskStore.swift
  Sources/Storage/Janitor.swift
)
for f in "${SOURCES[@]}"; do
  [ -f "$f" ] || { printf '\033[0;31m✗\033[0m 找不到 %s\n' "$f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 🚨 全程在一个临时目录里跑。
# 这个脚本会调 `wipeAllData()`，那是真删磁盘 —— 万一目录没换成功而打到了
# 用户真实的 ~/Library/Application Support/Perch，就是把人家的历史抹了。
#
# 换目录只能靠 `PERCH_SUPPORT_DIR`：macOS 的 `NSHomeDirectory()` 走 getpwuid，
# 改 `HOME` 环境变量对它毫无作用（实测过）。
# 双保险 —— 下面 Swift 里第一件事就是核对目录前缀，对不上直接退出，一个字节都不碰。
SUPPORT_DIR="$WORK/support"
mkdir -p "$SUPPORT_DIR"

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

// ── 安全闸：确认所有读写都落在临时目录里 ──
let expectedRoot = CommandLine.arguments.dropFirst().first ?? ""
let supportPath = DiskStore.applicationSupportDirectory.path
guard !expectedRoot.isEmpty, supportPath.hasPrefix(expectedRoot) else {
    print("\u{001B}[0;31m✗\u{001B}[0m 目录没落在临时目录里，拒绝继续：\(supportPath)")
    exit(1)
}

var failed = 0
var total = 0

@MainActor
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    total += 1
    if condition {
        print("\u{001B}[0;32m ok \u{001B}[0m \(name)")
    } else {
        failed += 1
        let extra = detail()
        print("\u{001B}[0;31mFAIL\u{001B}[0m \(name)\(extra.isEmpty ? "" : " —— \(extra)")")
    }
}

/// 跑一段主线程 runloop。
/// 落盘有 0.6 秒的合并窗口、读盘整段在后台，两处都必须真的等一等。
@MainActor
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

let manager = FileManager.default
let blobs = BlobStore.rootDirectory

@MainActor
func makeBlobDirectory(_ id: UUID, filename: String? = nil, modified: Date? = nil) {
    let directory = BlobStore.directory(for: id)
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    if let filename {
        try? Data("x".utf8).write(to: directory.appendingPathComponent(filename))
    }
    if let modified {
        try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: directory.path)
    }
}

@MainActor
func text(_ content: String, ageSeconds: TimeInterval = 0, pinned: Bool = false) -> PerchItem {
    let stamp = Date().addingTimeInterval(-ageSeconds)
    return PerchItem(
        kind: .text,
        preview: content,
        byteSize: Int64(content.utf8.count),
        dedupKey: content,
        createdAt: stamp,
        retentionStartedAt: stamp,
        isPinned: pinned
    )
}

// ══════════════════════════════════════════════════════════════
// 一、启动加载：本体缺失的条目丢掉，孤儿目录对账
// ══════════════════════════════════════════════════════════════

let keptImageID = UUID()
let deadImageID = UUID()      // 索引里有，磁盘上没有 → 加载时该被丢掉
let fileID = UUID()
let staleOrphanID = UUID()    // 磁盘上有，索引里没有，且已过宽限期 → 该被删
let freshOrphanID = UUID()    // 同为孤儿，但刚建好 → 宽限期内，不能删

makeBlobDirectory(keptImageID, filename: "content.png")
makeBlobDirectory(fileID, filename: "doc.txt")
makeBlobDirectory(staleOrphanID, modified: Date().addingTimeInterval(-10 * 60))
makeBlobDirectory(freshOrphanID)

let seeded = PerchIndex(
    clipboardItems: [
        text("alpha"),
        PerchItem(id: keptImageID, kind: .image, preview: "图片",
                  blobPath: "\(keptImageID.uuidString)/content.png",
                  byteSize: 1, dedupKey: "image|1"),
        PerchItem(id: deadImageID, kind: .image, preview: "丢了本体的图片",
                  blobPath: "\(deadImageID.uuidString)/content.png",
                  byteSize: 2, dedupKey: "image|2"),
    ],
    fileItems: [
        PerchItem(id: fileID, kind: .file, preview: "doc.txt",
                  blobPath: "\(fileID.uuidString)/doc.txt",
                  byteSize: 1, dedupKey: "doc.txt|1|0"),
    ]
)
try! DiskStore.save(seeded)

let store = PerchStore.shared
store.loadFromDisk()
pump(1.2)

check("加载：读回上次的剪贴板历史", store.clipboardItems.count == 2,
      "实得 \(store.clipboardItems.count) 条")
check("加载：本体已丢失的条目不进列表",
      !store.clipboardItems.contains { $0.id == deadImageID })
check("加载：文件区读回", store.fileItems.count == 1)
check("对账：过了宽限期的孤儿目录被删掉",
      !manager.fileExists(atPath: BlobStore.directory(for: staleOrphanID).path))
check("对账：刚建好的目录在宽限期内不动（正拖进来的东西不能被误删）",
      manager.fileExists(atPath: BlobStore.directory(for: freshOrphanID).path))
check("对账：索引里指向的目录不动",
      manager.fileExists(atPath: BlobStore.directory(for: keptImageID).path))

// ══════════════════════════════════════════════════════════════
// 二、去重：命中不新增，提到最前，计时重置
// ══════════════════════════════════════════════════════════════

store.add(text("beta"))
let alphaID = store.clipboardItems.first { $0.dedupKey == "alpha" }!.id
store.add(text("alpha"))

check("去重：同内容不新增", store.clipboardItems.count == 3,
      "实得 \(store.clipboardItems.count) 条")
check("去重：命中的那条提到最前", store.clipboardItems.first?.id == alphaID)
check("去重：保留原来的 id（不是删旧建新）",
      store.clipboardItems.filter { $0.dedupKey == "alpha" }.count == 1)
check("去重：计时重置到当下",
      abs(store.clipboardItems[0].retentionAnchor.timeIntervalSinceNow) < 2)

// 图片去重：新条目的本体已经落盘了，命中之后必须把它删掉，否则就是孤儿
let dupImageID = UUID()
makeBlobDirectory(dupImageID, filename: "content.png")
store.add(PerchItem(id: dupImageID, kind: .image, preview: "图片",
                    blobPath: "\(dupImageID.uuidString)/content.png",
                    byteSize: 1, dedupKey: "image|1"))
check("去重：命中时删掉新条目已落盘的本体，不留孤儿",
      !manager.fileExists(atPath: BlobStore.directory(for: dupImageID).path))
check("去重：老条目的本体留着",
      manager.fileExists(atPath: BlobStore.directory(for: keptImageID).path))

// 缩略图是异步生成的，落到磁盘上时条目可能早就被去重合并掉了。
// 那一步会把刚删掉的目录又建回来 —— 这里必须把它连目录一起收掉。
makeBlobDirectory(dupImageID, filename: "thumb.jpg")
store.setThumbnail("\(dupImageID.uuidString)/thumb.jpg", for: dupImageID)
check("缩略图晚到：条目已经不在了，目录要跟着删掉，不留孤儿",
      !manager.fileExists(atPath: BlobStore.directory(for: dupImageID).path))

// 还在架上的条目当然要正常挂上缩略图
store.setThumbnail("\(keptImageID.uuidString)/thumb.jpg", for: keptImageID)
check("缩略图正常挂上",
      store.clipboardItems.first { $0.id == keptImageID }?.thumbPath != nil)

// ══════════════════════════════════════════════════════════════
// 三、200 条上限：先保住全部固定项
// ══════════════════════════════════════════════════════════════

for index in 0..<5 {
    store.add(text("pinned-\(index)", pinned: true))
}
for index in 0..<300 {
    store.add(text("bulk-\(index)"))
}

check("上限：剪贴板不超过 200 条", store.clipboardItems.count == Janitor.clipboardLimit,
      "实得 \(store.clipboardItems.count) 条")
check("上限：5 条固定项一条都没被淘汰",
      store.clipboardItems.filter(\.isPinned).count == 5)
check("上限：淘汰的是最旧的，最新那条还在",
      store.clipboardItems.contains { $0.dedupKey == "bulk-299" })
check("上限：最早那批已经不在了",
      !store.clipboardItems.contains { $0.dedupKey == "bulk-0" })

// ══════════════════════════════════════════════════════════════
// 四、过期清理
// ══════════════════════════════════════════════════════════════

store.retention = .oneHour

let expiring = text("要过期的", ageSeconds: 2 * 3600)
let pinnedOld = text("固定的老条目", ageSeconds: 48 * 3600, pinned: true)
store.add(expiring)
store.add(pinnedOld)
store.sweepExpired()

check("过期：超过保存时长的条目被清掉",
      !store.clipboardItems.contains { $0.id == expiring.id })
check("过期：固定项永不过期",
      store.clipboardItems.contains { $0.id == pinnedOld.id })
check("过期：本体跟着一起删",
      !manager.fileExists(atPath: BlobStore.directory(for: expiring.id).path))

// 取消固定 → 倒计时从当下重新起算，不能立刻被下一次扫描收走
let createdBefore = store.clipboardItems.first { $0.id == pinnedOld.id }!.createdAt
let indexBefore = store.clipboardItems.firstIndex { $0.id == pinnedOld.id }!
store.togglePin(pinnedOld.id)
store.sweepExpired()
check("取消固定：倒计时从当下重算，不会立刻被清掉",
      store.clipboardItems.contains { $0.id == pinnedOld.id })
// 动了 createdAt 的话这条会跳到列表最前，可用户并没有重新复制过它。
check("取消固定：不动 createdAt",
      store.clipboardItems.first { $0.id == pinnedOld.id }?.createdAt == createdBefore)
check("取消固定：列表位置不变",
      store.clipboardItems.firstIndex { $0.id == pinnedOld.id } == indexBefore)

// 改设置立刻对全表生效
let old = text("三天前的东西", ageSeconds: 72 * 3600)
store.retention = .never
store.add(old)
store.sweepExpired()
check("保存时长设成「永不」时不清理",
      store.clipboardItems.contains { $0.id == old.id })
check("永不过期时不算到期时间", old.expiryDate(under: .never) == nil)

store.retention = .oneDay   // didSet 里会自己扫一遍，这里不手动调 sweep
check("改保存时长：立刻对已有条目生效",
      !store.clipboardItems.contains { $0.id == old.id })

// ══════════════════════════════════════════════════════════════
// 五、落盘
// ══════════════════════════════════════════════════════════════

store.remove(store.clipboardItems.last!.id)
pump(1.2)

let reloaded = DiskStore.load()
check("落盘：磁盘上的条数和内存一致",
      reloaded.clipboardItems.count == store.clipboardItems.count,
      "磁盘 \(reloaded.clipboardItems.count) / 内存 \(store.clipboardItems.count)")
check("落盘：顺序一致（新的在最前）",
      reloaded.clipboardItems.first?.id == store.clipboardItems.first?.id)
check("落盘：固定状态带得回来",
      reloaded.clipboardItems.filter(\.isPinned).count
          == store.clipboardItems.filter(\.isPinned).count)
check("落盘：图片只存相对路径，没有把本体 base64 进 JSON",
      (try? Data(contentsOf: DiskStore.indexURL)).map { $0.count < 512 * 1024 } ?? false)
check("原子写：不留 index.json.tmp",
      !manager.fileExists(atPath: DiskStore.indexURL.appendingPathExtension("tmp").path))

// 坏掉的索引不能让历史「读不出来还没得救」
try! Data("{ 这不是 JSON".utf8).write(to: DiskStore.indexURL)
let recovered = DiskStore.load()
check("索引损坏：不崩，从空索引开始", recovered.clipboardItems.isEmpty)
check("索引损坏：坏文件留一份 .corrupt 以备事后捞",
      manager.fileExists(atPath: DiskStore.indexURL.appendingPathExtension("corrupt").path))

// ══════════════════════════════════════════════════════════════
// 六、文件区多选与批量操作（M4）
// ══════════════════════════════════════════════════════════════
//
// 这一段和别的地方一样，错了要等用户「选了 3 个、只走了 2 个」才看得出来。

@MainActor
func file(_ name: String, pinned: Bool = false) -> PerchItem {
    let id = UUID()
    makeBlobDirectory(id, filename: name)
    return PerchItem(
        id: id, kind: .file, preview: name,
        blobPath: "\(id.uuidString)/\(name)",
        byteSize: 1, dedupKey: "\(name)|1|0", isPinned: pinned
    )
}

// 从干净的文件区开始，前面几节留下来的条目先清掉。
store.fileItems.map(\.id).forEach { store.remove($0) }
store.retention = .never

let f1 = file("one.txt")
let f2 = file("two.txt")
let f3 = file("three.txt")
[f1, f2, f3].forEach { store.add($0) }

check("多选：⌘A 选中文件区全部条目",
      { store.selectAllFiles(); return store.selectedFileIDs.count == 3 }())
check("多选：选中集按架上顺序给出，不是 Set 的随机顺序",
      store.selectedFileItems.map(\.id) == store.fileItems.map(\.id))
check("多选：Esc 清空选中", { store.clearSelection(); return store.selectedFileIDs.isEmpty }())

// 批量固定的口径：**全都固定了才是取消，否则一律固定**。
store.selectAllFiles()
store.toggleSelectedFilesPin()
check("批量固定：一次把选中的全固定上", store.selectedFileItems.allSatisfy(\.isPinned))
check("批量固定：全固定时 selectedFilesAllPinned 为真", store.selectedFilesAllPinned)

// 造一个混合态：其中一个取消固定。
store.togglePin(f2.id)
check("混合态：不是全固定", !store.selectedFilesAllPinned)
store.toggleSelectedFilesPin()
check("批量固定：混合态下点一下是「全部固定」，不是逐个反转",
      store.selectedFileItems.allSatisfy(\.isPinned),
      "实得 \(store.selectedFileItems.filter(\.isPinned).count) / 3 固定")

// 全固定 → 再点一下应该是全部取消，且倒计时从当下重新起算。
let beforeUnpin = Date()
store.toggleSelectedFilesPin()
check("批量固定：全固定时再点一下是全部取消",
      store.selectedFileItems.allSatisfy { !$0.isPinned })
check("批量取消固定：保存时长从当下重新起算，不是沿用几天前的起算点",
      store.selectedFileItems.allSatisfy { ($0.retentionStartedAt ?? .distantPast) >= beforeUnpin })

// 重命名：磁盘上的本体必须跟着改，只改显示名等于骗人（拖出去的还是老名字）。
let renamedDedup = store.fileItems.first { $0.id == f1.id }?.dedupKey
try? store.renameFile(f1.id, to: "renamed.txt")
let renamed = store.fileItems.first { $0.id == f1.id }
check("重命名：列表里的名字变了", renamed?.preview == "renamed.txt")
check("重命名：blobPath 指向新名字",
      renamed?.blobPath == "\(f1.id.uuidString)/renamed.txt")
check("重命名：磁盘上的本体真的改名了",
      manager.fileExists(atPath: BlobStore.directory(for: f1.id).appendingPathComponent("renamed.txt").path)
          && !manager.fileExists(atPath: BlobStore.directory(for: f1.id).appendingPathComponent("one.txt").path))
check("重命名：去重键不动（同一个源文件再拖一次仍然命中，不会多出一条）",
      renamed?.dedupKey == renamedDedup)

// 重名要抛错，不能悄悄覆盖 —— 同目录下还躺着缩略图 thumb.jpg。
try? Data("thumb".utf8).write(
    to: BlobStore.directory(for: f1.id).appendingPathComponent(BlobStore.thumbnailFilename)
)
var renameThrew = false
do {
    try store.renameFile(f1.id, to: BlobStore.thumbnailFilename)
} catch {
    renameThrew = true
}
check("重命名：撞上已存在的文件要抛错，不能覆盖", renameThrew)
check("重命名：抛错之后条目名字没被改坏",
      store.fileItems.first { $0.id == f1.id }?.preview == "renamed.txt")

// 批量移除：条目、本体、选中集三样一起走。
let doomedDirectories = store.selectedFileItems.map { BlobStore.directory(for: $0.id) }
store.selectedFileIDs = [f1.id, f3.id]
let removed = store.removeSelectedFiles()
check("批量移除：返回真实的移除条数", removed == 2, "实得 \(removed)")
check("批量移除：架上只剩没选中的那一个",
      store.fileItems.count == 1 && store.fileItems.first?.id == f2.id)
check("批量移除：选中集跟着清空", store.selectedFileIDs.isEmpty)
check("批量移除：blobs/ 下的本体一起删掉，不留孤儿",
      doomedDirectories.filter { manager.fileExists(atPath: $0.path) }.count == 1,
      "该留 1 个（没选中的那份），实得 \(doomedDirectories.filter { manager.fileExists(atPath: $0.path) }.count)")

// 到期清理也要把选中态里的死 id 摘掉，否则批量操作会作用在一个已经不存在的条目上。
let agedID = UUID()
makeBlobDirectory(agedID, filename: "aged.txt")
store.add(
    PerchItem(
        id: agedID, kind: .file, preview: "aged.txt",
        blobPath: "\(agedID.uuidString)/aged.txt",
        byteSize: 1, dedupKey: "aged.txt|1|0",
        retentionStartedAt: Date().addingTimeInterval(-2 * 60 * 60)
    )
)
store.selectAllFiles()
store.retention = .oneHour   // didSet 自己会扫一遍
check("清理：过期条目从选中集里一并摘掉",
      !store.selectedFileIDs.contains(agedID) && !store.fileItems.contains { $0.id == agedID })
store.retention = .never

// ══════════════════════════════════════════════════════════════
// 七、按来源 App 忽略（隐私）
// ══════════════════════════════════════════════════════════════
//
// 这一段判的是「谁给的」，不是「内容像什么」—— 它是唯一拦得住
// macOS 自带「密码」App 的机制（那个 App 一个标记都不打，2026-08-25 实测）。
// 判错的代价是「密码被原样记进历史」，所以口径必须有脚本盯着。

let defaults = UserDefaults.standard
defaults.removeObject(forKey: Preferences.Key.excludedSourceApps)

check("默认名单里有 macOS 自带的「密码」",
      Preferences.defaultExcludedSourceApps.contains("com.apple.Passwords"))
check("默认名单里有「钥匙串访问」",
      Preferences.defaultExcludedSourceApps.contains("com.apple.keychainaccess"))
check("没配置过时用默认名单",
      Preferences.excludedSourceApps == Preferences.defaultExcludedSourceApps)
check("默认就拦得住自带「密码」（这条规则默认是开的）",
      Preferences.isExcludedSource("com.apple.Passwords"))
check("bundle id 大小写不敏感",
      Preferences.isExcludedSource("com.apple.passwords"))
check("不在名单里的 App 照常上架",
      !Preferences.isExcludedSource("com.apple.Safari"))

// 🚨 认不出来源时**不能**忽略：宁可多记一条，也不要因为一次识别失败
// 就把用户真正想留的内容悄悄吞掉。
check("认不出来源（nil）时不忽略", !Preferences.isExcludedSource(nil))
check("来源是空串时不忽略", !Preferences.isExcludedSource(""))

// 用户把名单清空 = 关掉这条规则。
// 🚨 这里是 `object(forKey:)` 而不是 `stringArray(forKey:)` 的意义所在：
// 后者分不出「没配置过」和「配置成空」，会让「我明明清空了」变成「怎么又回来了」。
Preferences.excludedSourceApps = []
check("名单清空后规则关掉，不会回落到默认名单",
      Preferences.excludedSourceApps.isEmpty && !Preferences.isExcludedSource("com.apple.Passwords"))

Preferences.excludedSourceApps = ["com.example.vault"]
check("用户自定义的名单生效", Preferences.isExcludedSource("com.example.vault"))
check("自定义之后默认那两条不再自动生效",
      !Preferences.isExcludedSource("com.apple.Passwords"))

// 收尾：把这个键清掉，免得影响下一次运行和这台机器上的其它进程。
defaults.removeObject(forKey: Preferences.Key.excludedSourceApps)
check("清掉配置后回到默认名单",
      Preferences.excludedSourceApps == Preferences.defaultExcludedSourceApps)

// ══════════════════════════════════════════════════════════════
// 八、抹掉全部数据
// ══════════════════════════════════════════════════════════════

store.wipeAllData()
pump(1.2)

check("抹掉：两个区都空了", store.isEmpty)
check("抹掉：index.json 真的没了",
      !manager.fileExists(atPath: DiskStore.indexURL.path))
check("抹掉：blobs/ 真的没了", !manager.fileExists(atPath: blobs.path))
check("抹掉：待写的那次落盘被撤掉，没有把索引又写回来",
      !manager.fileExists(atPath: DiskStore.indexURL.path))

if failed == 0 {
    print("\n\u{001B}[0;32m✓\u{001B}[0m \(total) 项全部通过")
} else {
    print("\n\u{001B}[0;31m✗\u{001B}[0m \(failed) / \(total) 项不符")
    exit(1)
}
SWIFT

# 和 App 一样的语言版本与并发检查，避免「脚本里过、工程里不过」。
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$WORK/modcache" \
    -o "$WORK/run" "${SOURCES[@]}" "$WORK/main.swift"

PERCH_SUPPORT_DIR="$SUPPORT_DIR" "$WORK/run" "$SUPPORT_DIR"

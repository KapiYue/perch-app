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
// 六、抹掉全部数据
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

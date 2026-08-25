import AppKit
import SwiftUI

/// 「忽略这些 App 复制的内容」的名单编辑器，从设置页以 sheet 打开。
///
/// 为什么是 sheet 而不是直接铺在设置页里：设置窗口高度是**定死的 460×580**，
/// 而且有一条硬约束 —— 三段内容必须一屏装得下、不能出现滚动条，
/// 否则被挤到折叠线以下的就是「抹掉全部数据」（2026-08-22 踩过）。
/// 一个带增删的列表塞进去必然撑破那条线，所以只在主页面留一行「N 个 App…」。
struct ExcludedAppsView: View {

    @Environment(\.dismiss) private var dismiss

    /// 名单的唯一事实来源仍然是 `Preferences`，这里只是它的一个可编辑副本。
    /// 每次改动立刻写回去 —— 监听那边是每 0.5 秒直接读 `Preferences` 的，
    /// 攒到「完成」才写的话，用户改完不点完成就切走，改动就丢了。
    @State private var bundleIDs: [String] = Preferences.excludedSourceApps
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.excluded.title")
                .font(.headline)

            Text("settings.excluded.intro")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            list

            HStack {
                Button("settings.excluded.add") { addApps() }
                Button("settings.excluded.remove") { removeSelected() }
                    .disabled(selection.isEmpty)
                Button("settings.excluded.reset") { apply(Preferences.defaultExcludedSourceApps) }
                    .disabled(bundleIDs == Preferences.defaultExcludedSourceApps)

                Spacer()

                Button("settings.excluded.done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 340)
    }

    @ViewBuilder
    private var list: some View {
        if bundleIDs.isEmpty {
            // 空名单不能什么都不画 —— 用户会以为界面坏了，
            // 而这里恰恰要说清楚「空 = 这条规则现在不生效」。
            VStack(spacing: 4) {
                Text("settings.excluded.empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))
        } else {
            List(bundleIDs, id: \.self, selection: $selection) { bundleID in
                HStack(spacing: 8) {
                    if let icon = icon(for: bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "questionmark.app.dashed")
                            .frame(width: 20, height: 20)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayName(for: bundleID))
                            .font(.system(size: 12))
                        // bundle id 要显示出来：同名 App 不止一个，
                        // 而真正生效的是这个字符串，不是显示名。
                        Text(bundleID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 1)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    // MARK: - 增删

    /// 用系统的选取面板挑 App，让用户自己敲 bundle id 是不现实的。
    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "settings.excluded.panel.prompt")
        panel.message = String(localized: "settings.excluded.panel.message")

        guard panel.runModal() == .OK else { return }

        var updated = bundleIDs
        for url in panel.urls {
            // 认 bundle id 而不是路径：App 换个位置、改个名字，名单照样有效。
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            guard !updated.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { continue }
            updated.append(id)
        }
        apply(updated)
    }

    private func removeSelected() {
        apply(bundleIDs.filter { !selection.contains($0) })
        selection.removeAll()
    }

    private func apply(_ updated: [String]) {
        bundleIDs = updated
        Preferences.excludedSourceApps = updated
    }

    // MARK: - 显示

    private func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// App 没装（或者被删了）时退回 bundle id 本身，不要显示成空白一行。
    private func displayName(for bundleID: String) -> String {
        guard let url = appURL(for: bundleID) else {
            return String(localized: "settings.excluded.notInstalled")
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func icon(for bundleID: String) -> NSImage? {
        guard let url = appURL(for: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

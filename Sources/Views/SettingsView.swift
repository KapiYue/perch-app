import SwiftUI

/// 设置窗口。
///
/// 这里是普通的前台窗口，**可以正常用 SwiftUI `Button`** ——
/// 面板上那条「必须走 `.clickAction`」的限制只对面板成立（面板永远不是前台窗口）。
///
/// 「抹掉全部数据」和面板上常驻的 ⏸ 是「不做密码识别」那条产品决定的配套补偿，
/// 两个都必须留在显眼的地方 —— 一屏之内看得见，不能靠滚动才够得着。
struct SettingsView: View {

    @ObservedObject private var store = PerchStore.shared

    @AppStorage(Preferences.Key.autoExpandOnHover) private var autoExpandOnHover = true
    @AppStorage(Preferences.Key.skipConcealedContent) private var skipConcealedContent = false

    @State private var isConfirmingWipe = false

    /// 「忽略这些 App」的名单编辑器。
    /// 名单本身存在 `Preferences` 里（`@AppStorage` 支持不了 `[String]`），
    /// 这里只留一个计数用来画按钮，sheet 关掉时重新读一次。
    @State private var isEditingExcludedApps = false
    @State private var excludedAppCount = Preferences.excludedSourceApps.count

    var body: some View {
        Form {
            // 三段，各有小标题。
            // 早先是四段平铺 + 每段挂一坨三行灰脚注，没有标题分隔，
            // 整页看下来就是一片密密麻麻的说明文字（2026-08-22 真机反馈「样式乱糟糟」）。
            cleanupSection
            behaviorSection
            dataSection
        }
        .formStyle(.grouped)
        // 高度要一屏装得下三段全部内容，**不能出现滚动条** ——
        // 出现滚动条时被挤到折叠线以下的就是「抹掉全部数据」。
        // 英文文案比中文长，改动文案后要中英各量一次。
        // 🚨 高度按**英文**量，不是中文。英文脚注普遍比中文多折一行：
        // 520 时中文正好装下，英文却出滚动条、末尾那行还被切掉（2026-08-22 实测）。
        .frame(width: 460, height: 580)
        .alert("settings.wipe.confirm.title", isPresented: $isConfirmingWipe) {
            Button("settings.wipe.confirm.cancel", role: .cancel) {}
            Button("settings.wipe.confirm.ok", role: .destructive) {
                store.wipeAllData()
            }
        } message: {
            Text("settings.wipe.confirm.message")
        }
        .sheet(isPresented: $isEditingExcludedApps) {
            // 关掉时重新读一次：名单是在 sheet 里直接写进 Preferences 的。
            excludedAppCount = Preferences.excludedSourceApps.count
        } content: {
            ExcludedAppsView()
        }
    }

    private var cleanupSection: some View {
        Section {
            Picker(selection: $store.retention) {
                ForEach(Janitor.Retention.allCases, id: \.self) { option in
                    Text(LocalizedStringKey(option.titleKey)).tag(option)
                }
            } label: {
                Text("settings.retention.label")
            }
            .pickerStyle(.menu)
        } header: {
            Text("settings.section.cleanup")
        } footer: {
            footnote("settings.retention.footer")
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle(isOn: $autoExpandOnHover) {
                Text("settings.hover.label")
                Text("settings.hover.footer")
            }
            Toggle(isOn: $skipConcealedContent) {
                Text("settings.concealed.label")
                Text("settings.concealed.footer")
            }

            // 🔴 这一条和上面那条是**两套机制**，不要合并：
            // 上面看的是来源 App 有没有主动打标（打不打由它决定，所以默认关闭）；
            // 这一条看的是内容由谁给的（点名了就一定跳过，所以默认开着）。
            // macOS 自带的「密码」一个标记都不打，只有这一条覆盖得到它。
            LabeledContent {
                Button {
                    isEditingExcludedApps = true
                } label: {
                    Text(String(format: String(localized: "settings.excluded.count"), excludedAppCount))
                }
            } label: {
                Text("settings.excluded.label")
                Text("settings.excluded.footer")
            }
        } header: {
            Text("settings.section.behavior")
        }
    }

    private var dataSection: some View {
        Section {
            LabeledContent {
                Text(usage).foregroundStyle(.secondary)
            } label: {
                Text("settings.storage.label")
            }

            LabeledContent {
                Text(verbatim: "~/Library/Application Support/Perch/")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } label: {
                Text("settings.storage.path")
            }

            HStack {
                Button(role: .destructive) {
                    isConfirmingWipe = true
                } label: {
                    Text("settings.wipe.button")
                }
                .disabled(store.isEmpty)

                Spacer()
            }
        } header: {
            Text("settings.section.data")
        } footer: {
            footnote("settings.storage.footer")
        }
    }

    /// `剪贴板 183 · 文件 4 · 12.6 MB`
    ///
    /// 占用按条目自己记的字节数加总，不去枚举 `blobs/` ——
    /// 那是磁盘 I/O，不该挂在一个每次重绘都会读的属性上。
    private var usage: String {
        String(
            format: String(localized: "settings.storage.usage"),
            store.clipboardItems.count,
            store.fileItems.count,
            Formatters.size(store.totalByteSize)
        )
    }

    private func footnote(_ key: LocalizedStringKey) -> some View {
        Text(key).fixedSize(horizontal: false, vertical: true)
    }
}

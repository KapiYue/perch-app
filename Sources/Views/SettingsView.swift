import SwiftUI

/// 设置窗口。
///
/// M3 补齐：自动保存时长、全局快捷键、开机启动（SMAppService）、
/// 当前磁盘占用、抹掉全部数据。
/// 其中「抹掉全部数据」和面板上的暂停按钮是不做密码识别的配套补偿，必须有。
struct SettingsView: View {

    var body: some View {
        TabView {
            generalTab
                .tabItem { Text("settings.general") }
        }
        .frame(width: 440, height: 260)
    }

    private var generalTab: some View {
        VStack {
            Text("settings.placeholder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

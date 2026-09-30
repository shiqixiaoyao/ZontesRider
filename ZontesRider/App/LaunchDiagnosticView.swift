import SwiftUI
import UIKit

// MARK: - 裸诊断界面（连续启动失败时的兜底宿主）
//
// 这一页刻意**不依赖任何项目模块**：不用苏联风主题、不碰 SwiftData、
// 不碰蓝牙、不碰网络，只用系统字体与颜色。
// 目的只有一个：哪怕 App 其他部分有致命问题，「这一页一定能显示出来」，
// 从而把「上次启动死在哪一步 / 崩了什么 / 装的哪一版 / 什么系统」交到用户手上。

struct LaunchDiagnosticView: View {

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("升仕车机 · 安全诊断模式")
                    .font(.title3.bold())

                Text("检测到 App 连续两次启动失败，已跳过正常界面。请把本页截图发给开发者，即可定位。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                field("App 版本 / 系统", "\(appVersion) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
                field("失败次数", "\(LaunchTrace.attempts)")
                field("上次止于", LaunchTrace.phase ?? "（无记录）")
                field("崩溃记录", LaunchTrace.crash ?? "（没有 NSException，多半是 Swift 致命错误，看上面的「上次止于」即可定位）")
                field("日志文件", "系统「文件」App → 我的 iPhone → 升仕车机 → launch.phase.txt / last-crash.txt")

                Button {
                    LaunchTrace.reset()
                    exit(0)
                } label: {
                    Text("清除失败记录并退出（下次重新正常启动）")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

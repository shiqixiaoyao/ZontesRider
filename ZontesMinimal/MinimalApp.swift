import SwiftUI

// MARK: - 最小复现包（ZT-Minimal）
//
// 存在的唯一目的：把「点开即闪退」这件事一刀切成两半。
//
//   · 本包能正常打开 → 说明**签名 / 打包 / 装机链路**没问题，
//     闪退出在 ZontesRider 的代码里 → 再回主包二分。
//   · 本包也闪退   → 说明与代码无关，是 AltStore/证书/描述文件这条链路
//     （免费账号 7 天过期、同一 bundle id 被不同证书签过、entitlement 不被
//      免费 profile 覆盖……）→ 换装机方式，别再改代码。
//
// 纪律：只依赖 SwiftUI + Foundation。
// 不用 SwiftData、不用 CoreBluetooth、不用网络、不用项目主题，
// 连 `@State` 都不需要 —— 排除一切变量。

private let ztmMarkerURL: URL = {
    let fm = FileManager.default
    return (try? fm.url(for: .documentDirectory, in: .userDomainMask,
                        appropriateFor: nil, create: true))?
        .appendingPathComponent("launch.phase.txt")
        ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("launch.phase.txt")
}()

@main
struct MinimalApp: App {
    init() {
        try? "minimal.init".data(using: .utf8)?.write(to: ztmMarkerURL, options: .atomic)
    }

    var body: some Scene {
        WindowGroup {
            MinimalProbeView()
        }
    }
}

private struct MinimalProbeView: View {
    var body: some View {
        VStack(spacing: 18) {
            Text("ZT")
                .font(.system(size: 68, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 132, height: 132)
                .background(Color(red: 0.62, green: 0.11, blue: 0.11))
                .clipShape(RoundedRectangle(cornerRadius: 20))

            Text("最小复现包")
                .font(.title2.bold())

            Text("这一屏能显示，就证明\n签名、打包、装机链路都是好的。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                row("包标识", Bundle.main.bundleIdentifier ?? "—")
                row("版本", (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—")
                row("启动时间", Date().formatted(date: .omitted, time: .standard))
                row("系统", ProcessInfo.processInfo.operatingSystemVersionString)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 8)
        }
        .padding()
        .onAppear {
            try? "minimal.stable".data(using: .utf8)?.write(to: ztmMarkerURL, options: .atomic)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).monospacedDigit()
        }
        .font(.caption2)
    }
}

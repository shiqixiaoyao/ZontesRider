import SwiftUI
import SwiftData
import UIKit

// MARK: - 底部工段

public enum AppTab: Int, CaseIterable, Identifiable {
    case dashboard
    case track
    case fuel
    case status
    case profile

    public var id: Int { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "仪表"
        case .track:     return "轨迹"
        case .fuel:      return "油耗"
        case .status:    return "车况"
        case .profile:   return "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "speedometer"
        case .track:     return "map"
        case .fuel:      return "fuelpump.fill"
        case .status:    return "wrench.and.screwdriver"
        case .profile:   return "person.crop.circle"
        }
    }
}

// MARK: - 根容器

/// App 根视图：系统 TabView 管状态，机械 tab 栏管外观。
/// 工段顺序：仪表 / 轨迹 / 油耗 / 车况 / 我的（油耗嵌在轨迹与车况之间）。
public struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @State private var selection: AppTab = .dashboard
    /// 全局唯一蓝牙会话：控车指令经它下发给车机（pkeCode 随选中车辆重建）
    /// 惰性：init 不碰 CoreBluetooth，只有用户点「连接车机」才建栈
    @State private var ble = BLESession(pkeCode: "")
    /// 安全模式：**只有真的留下了异常记录**（NSSetUncaughtExceptionHandler 落盘的 last-crash.txt）
    /// 才降级启动——不挂蓝牙会话，先把界面撑起来让用户能进「我的」看诊断。
    /// 注意不要用「上次没跑到 stable」作为判据：首次安装、以及用户主动杀进程都会命中，
    /// 会造成「第一次打开就被判为异常」的误伤。
    @State private var safeMode = LaunchTrace.crash != nil

    /// SwiftData 容器是否可用。不可用时**不构造**油耗工段（它有 @Query，
    /// 环境里没有容器会直接 fatalError）——退化成提示页，其余工段照常。
    private let fuelStoreAvailable: Bool

    // BLESession 是 MainActor 隔离类型，init 必须在主线程上下文求值
    @MainActor public init(fuelStoreAvailable: Bool = true) {
        self.fuelStoreAvailable = fuelStoreAvailable
    }

    public var body: some View {
        TabView(selection: $selection) {
            DashboardContainer(ble: safeMode ? nil : ble)
                .tag(AppTab.dashboard)

            TrackView()
                .tag(AppTab.track)

            // ⚠️ 这里必须是条件分支而不是包一个可选视图：
            //    油耗工段用 @Query，环境里没有 ModelContainer 时会直接致命错误。
            //    tag 打在 Group 上（而不是两个分支各自打），避免 _ConditionalContent
            //    切换时 tab 选中态出现歧义。
            Group {
                if fuelStoreAvailable {
                    FuelTrackerView()
                } else {
                    FuelStoreUnavailableView()
                }
            }
            .tag(AppTab.fuel)

            VehicleStatusView()
                .tag(AppTab.status)

            ProfileView()
                .tag(AppTab.profile)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SovietTabBar(selection: $selection)
        }
        .tint(SovietPalette.brass)
        .safeAreaInset(edge: .top, spacing: 0) {
            if safeMode {
                SafeModeBanner {
                    LaunchTrace.clearCrash()
                    safeMode = false
                }
            }
        }
        .onAppear { LaunchTrace.mark("root.appear") }
        .task {
            LaunchTrace.mark("root.task")
            if !safeMode {
                ble.reconfigure(pkeCode: auth.activePKECode ?? "")
            }
            await runProbeIfNeeded()
        }
        .onChange(of: auth.activePKECode) { _, newValue in
            guard !safeMode else { return }
            ble.reconfigure(pkeCode: newValue ?? "")
        }
    }

    // MARK: - CI 探针（默认关闭，只影响带 ZR_PROBE=1 启动的进程）
    //
    // 背景：2026-10-01 用户又报「闪退」，但 CI 冒烟一直是绿的 ——
    // 因为冒烟只**启动** App、不切页面，**页面级崩溃它根本抓不到**（上次的
    // `1..<0` 区间 trap 就是「构造即崩」，属于少数能在启动路径上暴露的情况）。
    //
    // 所以这里加一条探针：带环境变量启动时，自动把五个工段逐个切一遍，
    // 每切一个就打一个 phase 点。哪个工段一渲染就崩，`launch.phase.txt`
    // 就会停在 `probe.<编号>` 上，CI 再据此判失败——把「用户报闪退 → 我们猜」
    // 变成「CI 自己复现并指出工段」。
    //
    // CI 侧的开启方式：`SIMCTL_CHILD_ZR_PROBE=1 xcrun simctl launch <udid> <bundle>`

    private func runProbeIfNeeded() async {
        guard ProcessInfo.processInfo.environment["ZR_PROBE"] == "1" else { return }
        // 启动自带的 stable 打点在挂载后 2s 写；先等它落定，免得被 probe 打点覆盖
        try? await Task.sleep(for: .seconds(3))
        LaunchTrace.mark("probe.begin")
        for tab in AppTab.allCases {
            LaunchTrace.mark("probe.\(tab.rawValue)")
            selection = tab
            // 每个工段驻留久一点：既让 body 求值，也让 onAppear/网络回调跑起来
            try? await Task.sleep(for: .seconds(3))
        }
        LaunchTrace.mark("probe.done")
    }
}

// MARK: - 油耗工段不可用（数据库起不来时的降级形态）
//
// ⚠️ 这一页**绝不能碰 SwiftData**（不写 @Query / @Environment(\.modelContext)），
//    否则在没有容器的环境里会直接崩，降级就白做了。

private struct FuelStoreUnavailableView: View {
    var body: some View {
        ZStack {
            SovietPalette.castIron.ignoresSafeArea()
            VStack(spacing: 14) {
                HazardStripes()
                SovietBanner("油耗工段")
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 30))
                        .foregroundStyle(SovietPalette.brass)
                    Text("本地数据库不可用")
                        .font(.soviet(14))
                        .tracking(2)
                        .foregroundStyle(SovietPalette.brass)
                    Text("本次启动没能建起本地数据库，油耗记录暂不可用。\n"
                         + "其余工段不受影响。可到「我的」查看启动诊断。")
                        .font(.soviet(10))
                        .foregroundStyle(SovietPalette.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 26)
                Spacer()
                HazardStripes()
            }
        }
    }
}

// MARK: - 安全模式提示条

/// 上次启动留下了异常记录时出现在顶部。
/// 点「恢复正常」会清掉异常记录并装配蓝牙会话——这样即使某处仍有问题，
/// 用户至少能进 App 看诊断。
private struct SafeModeBanner: View {
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
            Text("安全模式：上次启动异常，蓝牙会话已停用（诊断见「我的」）")
                .font(.soviet(10))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button("恢复正常", action: restore)
                .font(.soviet(10))
                .tracking(1)
                .foregroundStyle(SovietPalette.castIron)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SovietPalette.brass)
                .border(SovietPalette.black, width: 2)
                .buttonStyle(.plain)
        }
        .foregroundStyle(SovietPalette.brassPale)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(SovietPalette.redDark)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SovietPalette.black).frame(height: 2)
        }
    }
}

// MARK: - 仪表工段容器（登录态决定真实/演示数据）
//
// ⚠️ 这里刻意**不做 if/else 分支建 View**：
//   上一版写 `if auth.isLoggedIn { DashboardView(viewModel: VM(provider: auth)) } else { DashboardView() }`，
//   两个分支产出同类型视图，SwiftUI 复用 @State 时可能留下「没有数据源的 VM」，
//   表现就是「登录后车况一直不刷新」。现在容器自己持有唯一 VM，
//   登录态一变就用 task(id:) 注入数据源并启动轮询，与视图身份无关。

private struct DashboardContainer: View {
    @Environment(AuthStore.self) private var auth
    let ble: BLESession?

    @State private var model = DashboardViewModel(connection: .connecting)

    var body: some View {
        DashboardView(viewModel: model, ble: ble)
            .task(id: auth.isLoggedIn) {
                if auth.isLoggedIn {
                    model.bind(provider: CloudTelemetryProvider(auth: auth))
                    model.startPolling()
                } else {
                    model.unbindProvider()
                }
            }
            .onChange(of: auth.activePKECode) { _, _ in
                // 换车：立即用新车钥匙拉一次，不等下一个轮询周期
                guard auth.isLoggedIn else { return }
                Task { await model.refresh() }
            }
    }
}

// MARK: - 机械 tab 栏（黑底粗边，选中工段红底金字）

public struct SovietTabBar: View {
    @Binding var selection: AppTab

    public init(selection: Binding<AppTab>) {
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 18))
                        Text(tab.title)
                            .font(.soviet(10))
                            .tracking(2)
                    }
                    .foregroundStyle(selection == tab ? SovietPalette.brass : SovietPalette.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(selection == tab ? SovietPalette.revolutionRed : Color.clear)
                    .overlay(alignment: .top) {
                        if selection == tab {
                            Rectangle()
                                .fill(SovietPalette.brass)
                                .frame(height: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .background(SovietPalette.steelDark)
        .overlay(alignment: .top) {
            Rectangle().fill(SovietPalette.black).frame(height: 2)
        }
    }
}

// MARK: - 建设中工段占位页

public struct SovietPlaceholderView: View {
    let title: String
    let subtitle: String
    var milestone: String? = nil

    public init(title: String, subtitle: String, milestone: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.milestone = milestone
    }

    public var body: some View {
        ZStack {
            SovietPalette.castIron.ignoresSafeArea()

            VStack(spacing: 0) {
                HazardStripes()
                SovietBanner(title)

                Spacer()

                VStack(spacing: 14) {
                    RedStarSeal(size: 56)

                    Text("工段建设中")
                        .font(.soviet(17))
                        .tracking(4)
                        .foregroundStyle(SovietPalette.brass)

                    Text(subtitle)
                        .font(.soviet(12))
                        .foregroundStyle(SovietPalette.textMuted)
                        .multilineTextAlignment(.center)

                    if let milestone {
                        Text(milestone)
                            .font(.soviet(11))
                            .foregroundStyle(SovietPalette.textFaint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(SovietPalette.steelLight)
                            .border(SovietPalette.black, width: 2)
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                HazardStripes()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 预览

#Preview("根框架 · 默认仪表") {
    RootView()
        .environment(AuthStore())
        .modelContainer(FuelEntry.previewContainer)
}

#Preview("tab 栏") {
    SovietTabBar(selection: .constant(.fuel))
        .padding(.vertical, 40)
        .background(SovietPalette.castIron)
}

#Preview("建设中工段") {
    SovietPlaceholderView(
        title: "轨迹工段",
        subtitle: "骑行轨迹 · GPS 回放 · 路线归档",
        milestone: "待接入：CoreLocation 轨迹记录"
    )
}

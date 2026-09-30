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
    @State private var selection: AppTab = .dashboard

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
            DashboardView()
                .tag(AppTab.dashboard)

            SovietPlaceholderView(
                title: "轨迹工段",
                subtitle: "骑行轨迹 · GPS 回放 · 路线归档",
                milestone: "待接入：CoreLocation 轨迹记录"
            )
            .tag(AppTab.track)

            FuelTrackerView()
                .tag(AppTab.fuel)

            SovietPlaceholderView(
                title: "车况工段",
                subtitle: "故障码详情 · 保养周期 · 胎压历史",
                milestone: "待接入：getDataService 云端车况"
            )
            .tag(AppTab.status)

            SovietPlaceholderView(
                title: "我的工段",
                subtitle: "账号 · 车辆绑定 · 外观与单位设置",
                milestone: "待接入：ifino OAuth2 登录"
            )
            .tag(AppTab.profile)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SovietTabBar(selection: $selection)
        }
        .tint(SovietPalette.brass)
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

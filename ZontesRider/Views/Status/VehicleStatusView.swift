import SwiftUI

// MARK: - 车况工段（真实 getHomeData 全字段）

public struct VehicleStatusView: View {
    @Environment(AuthStore.self) private var auth
    @State private var telemetry: VehicleTelemetry?
    @State private var errorText: String?
    @State private var loading = false

    public init() {}

    public var body: some View {
        ZStack {
            SovietPalette.castIron.ignoresSafeArea()

            VStack(spacing: 0) {
                HazardStripes()
                SovietBanner("车况检阅台")

                if !auth.isLoggedIn {
                    loginRequired
                } else {
                    content
                }

                HazardStripes()
            }
        }
        .task { await load() }
        .preferredColorScheme(.dark)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let t = telemetry {
                    identityCard(t)
                    readingsGrid(t)
                    tireCard(t)
                    signalCard(t)
                    footerCard(t)
                } else if loading {
                    ProgressView()
                        .tint(SovietPalette.brass)
                        .padding(.top, 80)
                } else if let errorText {
                    errorCard(errorText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .refreshable { await load() }
    }

    private var loginRequired: some View {
        VStack(spacing: 14) {
            Spacer()
            RedStarSeal(size: 52)
            Text("未登记通行")
                .font(.soviet(16))
                .tracking(3)
                .foregroundStyle(SovietPalette.brass)
            Text("请先在「我的」工段登录升仕账号\n车况数据经 ifino 云端下发")
                .font(.soviet(11))
                .foregroundStyle(SovietPalette.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Spacer()
        }
    }

    // MARK: 卡片

    private func identityCard(_ t: VehicleTelemetry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.displayName)
                    .font(.soviet(17))
                    .foregroundStyle(SovietPalette.brass)
                Text(t.pkeCode.isEmpty ? "—" : "PKE \(t.pkeCode)")
                    .font(.soviet(10))
                    .foregroundStyle(SovietPalette.textMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(t.lockState.label)
                    .font(.soviet(12))
                    .tracking(1)
                    .foregroundStyle(t.lockState == .unlocked ? SovietPalette.redBright : SovietPalette.ok)
                Text("更新于 \(t.updatedAt.map { Self.clock.string(from: $0) } ?? "--")")
                    .font(.soviet(9))
                    .foregroundStyle(SovietPalette.textFaint)
            }
        }
        .padding(14)
        .constructivistCard()
    }

    private func readingsGrid(_ t: VehicleTelemetry) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                DataCell(
                    label: "电瓶电压",
                    value: t.batteryVoltage.map { String(format: "%.1f", $0) } ?? "--",
                    unit: "V",
                    tint: t.isBatteryLow ? SovietPalette.danger : SovietPalette.brassPale
                )
                DataCell(
                    label: "燃油",
                    value: t.fuelPercent.map { "\($0)" } ?? "--",
                    unit: "%",
                    tint: t.isFuelLow ? SovietPalette.danger : SovietPalette.brassPale
                )
            }
            HStack(spacing: 10) {
                DataCell(label: "总里程",
                         value: t.odometerKm.map { String(format: "%.1f", $0) } ?? "--", unit: "km")
                DataCell(label: "预计续航",
                         value: t.rangeKm.map { "\($0)" } ?? "--", unit: "km")
            }
            HStack(spacing: 10) {
                DataCell(label: "实时车速",
                         value: t.speedKmh.map { String(format: "%.0f", $0) } ?? "静止/无效",
                         unit: t.speedKmh != nil ? "km/h" : nil)
                DataCell(label: "GPS 卫星",
                         value: t.satelliteCount.map { "\($0)" } ?? "--", unit: "颗")
            }
        }
    }

    private func tireCard(_ t: VehicleTelemetry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SovietSectionLabel("胎压检测")
            HStack(spacing: 10) {
                tireGauge("前轮", actual: t.frontTireKpa, rated: t.frontTireRated,
                          low: t.isFrontTireLow)
                tireGauge("后轮", actual: t.rearTireKpa, rated: t.rearTireRated,
                          low: t.isRearTireLow)
            }
        }
        .padding(14)
        .constructivistCard(borderColor: SovietPalette.black)
    }

    private func tireGauge(_ name: String, actual: Int?, rated: Int?, low: Bool) -> some View {
        VStack(spacing: 6) {
            Text(name)
                .font(.soviet(10))
                .foregroundStyle(SovietPalette.textMuted)
            Text(actual.map { String(format: "%03d", $0) } ?? "---")
                .font(.soviet(22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(low ? SovietPalette.danger : SovietPalette.brass)
            Text("额定 \(rated.map { "\($0)" } ?? "--") kPa")
                .font(.soviet(9))
                .foregroundStyle(SovietPalette.textFaint)
            if low {
                Text("气压偏低")
                    .font(.soviet(9))
                    .tracking(1)
                    .foregroundStyle(SovietPalette.castIron)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SovietPalette.danger)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(SovietPalette.steelDark)
        .border(low ? SovietPalette.danger : SovietPalette.black, width: 2)
    }

    private func signalCard(_ t: VehicleTelemetry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SovietSectionLabel("通讯链路")
            HStack {
                Text("T-Box 信号")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        Rectangle()
                            .fill(i < (t.tboxSignal ?? 0) ? SovietPalette.brass : SovietPalette.track)
                            .frame(width: 6, height: CGFloat(6 + i * 3))
                    }
                }
                Text(t.tboxSignal.map { "\($0)/5" } ?? "--")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textSecondary)
                    .padding(.leading, 6)
            }
        }
        .padding(14)
        .constructivistCard(borderColor: SovietPalette.black)
    }

    private func footerCard(_ t: VehicleTelemetry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("故障码")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
                Text(t.faultCodes.isEmpty ? "无异常" : t.faultCodes.joined(separator: " "))
                    .font(.soviet(12))
                    .foregroundStyle(t.faultCodes.isEmpty ? SovietPalette.ok : SovietPalette.danger)
            }
            Spacer()
            if loading { ProgressView().tint(SovietPalette.brass) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .constructivistCard(cut: 8, borderColor: SovietPalette.black)
    }

    private func errorCard(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(SovietPalette.danger)
            Text(msg)
                .font(.soviet(12))
                .foregroundStyle(SovietPalette.danger)
                .multilineTextAlignment(.center)
            Button("重新拉取") { Task { await load() } }
                .buttonStyle(HeavyMetalButtonStyle())
        }
        .padding(20)
        .constructivistCard(borderColor: SovietPalette.danger)
        .padding(.top, 40)
    }

    // MARK: 加载

    private func load() async {
        guard auth.isLoggedIn else { return }
        loading = true
        defer { loading = false }
        do {
            telemetry = try await auth.fetchHomeData()
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 预览

#Preview("车况（未登录门岗）") {
    VehicleStatusView()
        .environment(AuthStore())
}

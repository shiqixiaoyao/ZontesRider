import SwiftUI

// MARK: - 车况工段（真实 getHomeData 全字段）

public struct VehicleStatusView: View {
    @Environment(AuthStore.self) private var auth
    @State private var telemetry: VehicleTelemetry?
    @State private var errorText: String?
    @State private var loading = false
    /// 当前显示的是本地缓存（还没拿到实时数据，或实时失败后回落）
    @State private var stale = false
    @State private var cacheAt: Date?
    @State private var cacheEntries: [LocalStore.Entry] = []
    @State private var showTrace = false

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
        // 用 task(id:) 而不是 task：登录态一变就重新拉，否则「先开 App 后登录」
        // 的用户切到本页会永远看到空白（task 只在首次出现时执行一次）
        .task(id: auth.isLoggedIn) { await load() }
        .preferredColorScheme(.dark)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                // 实时失败但手里有数据时：错误只占一条窄带，数据照常显示（数据保留优先）
                if let errorText, telemetry != nil {
                    inlineError(errorText)
                }
                if let t = telemetry {
                    identityCard(t)
                    cloudCard
                    readingsGrid(t)
                    tireCard(t)
                    signalCard(t)
                    localDataCard
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
                if stale, let at = cacheAt {
                    Text("本地缓存 · \(Self.clock.string(from: at))")
                        .font(.soviet(9))
                        .foregroundStyle(SovietPalette.brass)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay { Rectangle().stroke(SovietPalette.brass, lineWidth: 1) }
                } else {
                    Text("更新于 \(t.updatedAt.map { Self.clock.string(from: $0) } ?? "--")")
                        .font(.soviet(9))
                        .foregroundStyle(SovietPalette.textFaint)
                }
            }
        }
        .padding(14)
        .constructivistCard()
    }

    /// 云端链路自检：这一屏用来回答「是不是真的连着升仕后台」
    private var cloudCard: some View {
        let h = auth.health
        return VStack(alignment: .leading, spacing: 8) {
            SovietSectionLabel("云端链路自检")
            row("网关", "www.ifino.com:8081/zontespkeapp/api")
            row("接口", "getHomeData（真实车况）")
            row("车辆 PKE", auth.activePKECode ?? "—")
            HStack {
                Text("链路状态")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
                Spacer()
                Text(h.ok ? "已接通" : (h.lastError ?? "未探测"))
                    .font(.soviet(11))
                    .foregroundStyle(h.ok ? SovietPalette.ok : SovietPalette.danger)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.trailing)
            }
            if let at = h.lastSuccessAt {
                HStack {
                    Text("最近成功")
                        .font(.soviet(11))
                        .foregroundStyle(SovietPalette.textMuted)
                    Spacer()
                    Text(Self.clock.string(from: at))
                        .font(.soviet(11))
                        .monospacedDigit()
                        .foregroundStyle(SovietPalette.textSecondary)
                }
            }
        }
        .padding(14)
        .constructivistCard(borderColor: SovietPalette.black)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
                .font(.soviet(11))
                .foregroundStyle(SovietPalette.textMuted)
            Spacer()
            Text(v)
                .font(.soviet(11))
                .foregroundStyle(SovietPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
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

    // MARK: 本地数据（数据保留的可见凭证 + 一键清理）

    private var localDataCard: some View {
        let total = cacheEntries.reduce(0) { $0 + $1.bytes }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SovietSectionLabel("本地数据")
                Spacer()
                Text(total > 0 ? Self.sizeText(total) : "空")
                    .font(.soviet(10))
                    .foregroundStyle(SovietPalette.textFaint)
            }

            if cacheEntries.isEmpty {
                Text("暂无缓存。成功拉到一次车况 / 轨迹后会自动落盘（沙盒 Application Support/ZontesRider）。")
                    .font(.soviet(10))
                    .foregroundStyle(SovietPalette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(cacheEntries, id: \.name) { e in
                    HStack(spacing: 8) {
                        Text(Self.friendly(e.name))
                            .font(.soviet(10))
                            .foregroundStyle(SovietPalette.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text(Self.sizeText(e.bytes))
                            .font(.soviet(10))
                            .monospacedDigit()
                            .foregroundStyle(SovietPalette.textFaint)
                        Text(e.modifiedAt.map { Self.clock.string(from: $0) } ?? "--")
                            .font(.soviet(10))
                            .monospacedDigit()
                            .foregroundStyle(SovietPalette.textFaint)
                    }
                }
            }

            row("缓存目录", "沙盒 · Application Support/ZontesRider")
            row("网络留档", RawTrafficLog.tail(limit: 1).isEmpty ? "暂无" : "Documents/\(RawTrafficLog.fileName)")

            HStack(spacing: 8) {
                miniButton("刷新概览") { refreshLocalInfo() }
                miniButton(showTrace ? "收起原始响应" : "查看原始响应") { showTrace.toggle() }
                miniButton("清除缓存") {
                    auth.clearLocalCache()
                    refreshLocalInfo()
                }
            }

            if showTrace {
                let text = RawTrafficLog.tail(limit: 1400)
                Text(text.isEmpty ? "暂无网络留档（net-trace.log 为空）" : text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SovietPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(SovietPalette.steelDark)
                    .border(SovietPalette.black, width: 1)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .constructivistCard(borderColor: SovietPalette.black)
    }

    private func miniButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.soviet(10))
                .tracking(1)
                .foregroundStyle(SovietPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .overlay { Rectangle().stroke(SovietPalette.textMuted, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private static func friendly(_ name: String) -> String {
        if name == LocalStore.vehiclesFile { return "车辆列表" }
        if name.hasPrefix("telemetry-") { return "车况快照" }
        if name.hasPrefix("track-") {
            if name.contains("-30d") { return "轨迹 · 近 30 日" }
            if name.contains("-7d") { return "轨迹 · 近 7 日" }
            return "轨迹 · 今日"
        }
        return name
    }

    private static func sizeText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    private func refreshLocalInfo() {
        cacheEntries = auth.localCacheEntries()
    }

    /// 有数据时的错误提示：只占一条窄带，数据照常显示
    private func inlineError(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(SovietPalette.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text(stale ? "实时拉取失败（下方为本地缓存）" : "实时拉取失败")
                    .font(.soviet(10))
                    .foregroundStyle(SovietPalette.danger)
                Text(msg)
                    .font(.soviet(9))
                    .foregroundStyle(SovietPalette.textMuted)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SovietPalette.castIron)
        .border(SovietPalette.danger, width: 1)
    }

    private func footerCard(_ t: VehicleTelemetry) -> some View {        HStack {
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
        // 冷启动 / 断网：先把本地缓存摆上屏（用户诉求：数据要留下来）
        if telemetry == nil, let snap = auth.cachedTelemetry() {
            telemetry = snap.telemetry
            cacheAt = snap.at
            stale = true
        }
        loading = true
        defer { loading = false }
        do {
            let t = try await auth.fetchHomeData()
            telemetry = t
            stale = false
            cacheAt = nil
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if telemetry != nil { stale = true }
        }
        refreshLocalInfo()
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

import SwiftUI
import UIKit

// MARK: - 指令发送抽象

/// UI 层唯一的对外依赖。真实实现走 BLE / 云端，Mock 用于模拟器调试。
public protocol ControlCommandSending: Sendable {
    func send(_ action: ControlAction) async throws
}

/// 模拟发送：延迟 700ms 后成功，等价于一次蓝牙往返（仅预览 / 无真车演示用）
public struct MockCommandSender: ControlCommandSending {
    public init() {}
    public func send(_ action: ControlAction) async throws {
        try await Task.sleep(nanoseconds: 700_000_000)
    }
}

// MARK: - ViewModel

@Observable
public final class DashboardViewModel {
    public var telemetry: VehicleTelemetry
    public var connection: ConnectionBadge.State
    public var busyAction: ControlAction?
    public var banner: Banner?

    /// 车机蓝牙是否在线（由 DashboardView 从 BLESession 投影进来）
    public var bleReady = false
    /// 正在拉云端车况（用于按钮态）
    public var isRefreshing = false
    /// 最近一次拉取失败原因（UI 直接显示，避免「静默不刷新」）
    public var loadError: String?
    /// 当前展示的是**本地缓存**（冷启动先摆缓存；实时失败时回落到缓存，而不是清空）
    public var dataFromCache = false
    /// 本地缓存落盘时间
    public var cacheAt: Date?
    /// 本次会话是否成功拿到过**实时**车况
    public var hasLiveData = false
    /// 云端数据是否可用（未登录时为 false，界面展示演示数据）
    public var usesCloudData: Bool { provider != nil }

    private var sender: (any ControlCommandSending)?
    /// 可后绑定：登录完成 / 换车后由容器注入云端数据源。
    /// 上一版是 let，导致「视图先以未登录形态创建 → 拿到无数据源 VM → 登录后仍不刷新」。
    private var provider: (any TelemetryProvider)?
    private var pollTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?

    public init(
        telemetry: VehicleTelemetry = .sample,
        connection: ConnectionBadge.State = .connected(rssi: -62),
        sender: (any ControlCommandSending)? = nil,
        provider: (any TelemetryProvider)? = nil
    ) {
        self.telemetry = telemetry
        self.connection = connection
        self.sender = sender
        self.provider = provider
    }

    /// 登录态 / 换车后回填真实控车通道
    public func attach(sender: any ControlCommandSending) {
        self.sender = sender
    }

    /// 登录态变化时注入/替换云端数据源。重复注入同一来源是幂等的。
    /// 绑定后立刻把**本地缓存**摆上屏：冷启动/断网也有车况可看，
    /// 不用干等一次网络往返（拿到实时数据后会被 refresh 覆盖并去掉「缓存」标记）。
    @MainActor
    public func bind(provider: any TelemetryProvider) {
        self.provider = provider
        guard let cache = provider as? TelemetryCaching else { return }
        Task { [weak self] in
            guard let snap = await cache.cachedTelemetry() else { return }
            await MainActor.run {
                guard let self, !self.hasLiveData else { return }
                self.telemetry = snap.telemetry
                self.dataFromCache = true
                self.cacheAt = snap.at
            }
        }
    }

    /// 退出登录：摘掉数据源并停轮询，界面回落演示数据
    @MainActor
    public func unbindProvider() {
        stopPolling()
        provider = nil
        loadError = nil
        dataFromCache = false
        cacheAt = nil
        hasLiveData = false
        connection = .disconnected
    }

    public struct Banner: Identifiable, Sendable {
        public let id = UUID()
        let text: String
        let isError: Bool
    }

    public var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    /// 可见的控车项：坐垫 / 油箱依赖车型能力位
    public var availableActions: [ControlAction] {
        telemetry.supportsSeatAndTank
            ? ControlAction.allCases
            : [.unlock, .lock, .findVehicle, .arm]
    }

    // MARK: 车况轮询（provider 存在时生效）

    /// 立即拉一次，随后每 interval 秒轮询。重复调用安全（先取消旧任务）。
    @MainActor
    public func startPolling(interval: TimeInterval = 20) {
        guard provider != nil else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    @MainActor
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    @MainActor
    public func refresh() async {
        guard let provider else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let t = try await provider.fetchTelemetry()
            telemetry = t
            loadError = nil
            dataFromCache = false
            cacheAt = nil
            hasLiveData = true
            connection = .connected(rssi: t.tboxSignal.map { -115 + $0 * 10 } ?? -70)
        } catch is CancellationError {
            // 切页 / 退后台导致的取消：不是故障，不报错、不把连接标成断开
            return
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connection = .disconnected
            // 实时失败 → 回落到本地缓存：数据保留优先，错误原因照旧显性显示
            if !hasLiveData, let cache = provider as? TelemetryCaching,
               let snap = await cache.cachedTelemetry() {
                telemetry = snap.telemetry
                dataFromCache = true
                cacheAt = snap.at
            }
        }
    }

    // MARK: 控车

    @MainActor
    public func send(_ action: ControlAction) async {
        guard busyAction == nil else { return }
        busyAction = action
        defer { busyAction = nil }

        guard let sender else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showBanner("控车通道未就绪：请先登录并靠近车辆连接车机蓝牙", isError: true)
            return
        }

        do {
            try await sender.send(action)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showBanner("\(action.title)指令已送达车机", isError: false)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showBanner("\(action.title)失败：\(msg)", isError: true)
        }
    }

    @MainActor
    private func showBanner(_ text: String, isError: Bool) {
        banner = Banner(text: text, isError: isError)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run { self?.banner = nil }
        }
    }
}

// MARK: - 主界面（车辆监控站）

public struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var pendingConfirm: ControlAction?
    private let ble: BLESession?

    public init(viewModel: DashboardViewModel = DashboardViewModel(), ble: BLESession? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.ble = ble
    }

    public var body: some View {
        ZStack {
            SovietPalette.castIron.ignoresSafeArea()

            VStack(spacing: 0) {
                HazardStripes()
                SovietBanner("车辆监控站")

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        header
                        gauges
                        metrics
                        controls
                        footer
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }

                HazardStripes()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            LaunchTrace.mark("dashboard.appear")
            if let ble { viewModel.attach(sender: BLEGateway(session: ble)) }
            viewModel.startPolling()
        }
        .onDisappear { viewModel.stopPolling() }
        .onChange(of: ble?.linkState) { _, newValue in
            viewModel.bleReady = (newValue == .ready)
        }
        .alert(item: $pendingConfirm) { action in
            Alert(
                title: Text("确认\(action.title)？"),
                message: Text("执行后车辆将立即响应，请确认周围环境安全。"),
                primaryButton: .default(Text("执行")) {
                    Task { await viewModel.send(action) }
                },
                secondaryButton: .cancel()
            )
        }
        .overlay(alignment: .bottom) {
            if let banner = viewModel.banner {
                Text(banner.text)
                    .font(.soviet(12))
                    .foregroundStyle(banner.isError ? SovietPalette.redBright : SovietPalette.brass)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(SovietPalette.steelLight)
                    .border(SovietPalette.black, width: 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.banner?.id)
    }

    // MARK: 车辆身份 + 连接状态

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.telemetry.displayName)
                    .font(.soviet(15))
                    .foregroundStyle(SovietPalette.brassPale)
                Text(viewModel.telemetry.variant.isEmpty ? viewModel.telemetry.pkeCode : viewModel.telemetry.variant)
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                ConnectionBadge(state: viewModel.connection)
                if viewModel.dataFromCache, let at = viewModel.cacheAt {
                    Text("本地缓存 · \(Self.timeFormatter.string(from: at))")
                        .font(.soviet(9))
                        .foregroundStyle(SovietPalette.brass)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay { Rectangle().stroke(SovietPalette.brass, lineWidth: 1) }
                }
                if viewModel.usesCloudData {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await viewModel.refresh() }
                    } label: {
                        Text(viewModel.isRefreshing ? "拉取中…" : "刷新车况")
                            .font(.soviet(10))
                            .tracking(1)
                            .foregroundStyle(SovietPalette.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .overlay {
                                Rectangle().stroke(SovietPalette.textMuted, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isRefreshing)
                }
            }
        }
    }

    // MARK: 环形仪表

    private var gauges: some View {
        HStack(spacing: 10) {
            GaugeRing(
                ratio: viewModel.telemetry.voltageRatio,
                display: viewModel.telemetry.batteryVoltage.map { String(format: "%.1f", $0) } ?? "--",
                unit: "V",
                caption: viewModel.telemetry.isBatteryLow ? "电瓶电压 偏低" : "电瓶电压",
                tint: viewModel.telemetry.isBatteryLow ? SovietPalette.redBright : SovietPalette.brass
            )
            GaugeRing(
                ratio: Double(viewModel.telemetry.fuelPercent ?? 0) / 100,
                display: viewModel.telemetry.fuelPercent.map { "\($0)" } ?? "--",
                unit: "%",
                caption: viewModel.telemetry.isFuelLow ? "燃油 偏低" : "燃油",
                tint: viewModel.telemetry.isFuelLow ? SovietPalette.redBright : SovietPalette.brass
            )
        }
    }

    // MARK: 数据格

    private var metrics: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                DataCell(
                    label: "总里程",
                    value: viewModel.telemetry.odometerKm.map { String(format: "%.1f", $0) } ?? "--",
                    unit: "km"
                )
                DataCell(
                    label: "预计续航",
                    value: viewModel.telemetry.rangeKm.map { "\($0)" } ?? "--",
                    unit: "km"
                )
            }
            HStack(spacing: 10) {
                DataCell(label: "胎压 前 / 后", value: tireText, unit: "kPa", tint: tireTint)
                DataCell(
                    label: "T-Box 信号",
                    value: viewModel.telemetry.tboxSignal.map { "\($0)" } ?? "--",
                    unit: viewModel.telemetry.satelliteCount.map({ "· \($0) 星" })
                )
            }
        }
    }

    private var tireText: String {
        let f = viewModel.telemetry.frontTireKpa.map { String(format: "%03d", $0) } ?? "--"
        let r = viewModel.telemetry.rearTireKpa.map { String(format: "%03d", $0) } ?? "--"
        return "\(f) / \(r)"
    }

    private var tireTint: Color {
        let t = viewModel.telemetry
        let bad = t.isFrontTireLow || t.isRearTireLow || t.isFrontTireHigh || t.isRearTireHigh
        return bad ? SovietPalette.redBright : SovietPalette.brassPale
    }

    // MARK: 控车

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                SovietSectionLabel("控车台")
                Spacer()
                Text(viewModel.telemetry.lockState.label)
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textFaint)
            }

            if let ble {
                BLELinkRow(session: ble)
            } else {
                Text("演示数据 · 控车需登录并连接车机蓝牙")
                    .font(.soviet(10))
                    .foregroundStyle(SovietPalette.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3),
                spacing: 9
            ) {
                ForEach(viewModel.availableActions) { action in
                    ControlButton(
                        title: action.title,
                        systemImage: action.systemImage,
                        tint: action.tint,
                        isBusy: viewModel.busyAction == action,
                        // 控车走蓝牙，不依赖云端连通性：按钮恒可点，
                        // 失败时由链路层如实报错，避免「云端一断按钮就点不动」的误导
                        isEnabled: viewModel.busyAction == nil
                    ) {
                        if action.needsConfirmation {
                            pendingConfirm = action
                        } else {
                            Task { await viewModel.send(action) }
                        }
                    }
                }
            }

            Text("控车指令经蓝牙明文通道直发车机（需靠近车辆）。云端无 REST 控车端点，"
                 + "故离线控车为唯一可行路径。官方通道有握手：prime 帧 → 车机 ready ack → "
                 + "参数写 → 安全响应。握手结果会记在下面的帧日志里。")
                .font(.soviet(9))
                .foregroundStyle(SovietPalette.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            // 蓝牙帧日志：点一次解锁就能看到「发了什么 / 车机回了什么」，
            // 这是后续校准指令帧的唯一凭据（云端已证实无控车接口）
            Button {
                showBLETrace.toggle()
                if showBLETrace { bleTrace = BLETrace.tail() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text(showBLETrace ? "收起蓝牙帧日志" : "查看蓝牙帧日志（含握手，校准用）")
                        .font(.soviet(10))
                        .tracking(1)
                    Spacer()
                }
                .foregroundStyle(SovietPalette.brass)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .overlay { Rectangle().stroke(SovietPalette.brass, lineWidth: 1) }
            }
            .buttonStyle(.plain)

            if showBLETrace {
                Text(bleTrace.isEmpty
                     ? "暂无蓝牙帧记录（先在上方点「连接车机」或发一条指令）\n"
                       + "要看的关键行：TX-PRIME（握手帧）、ready ack / ready ack not received（通道认没认）、"
                       + "TX（指令帧）、RX（车机回帧）"
                     : bleTrace)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SovietPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(SovietPalette.steelDark)
                    .border(SovietPalette.black, width: 1)
                    .textSelection(.enabled)
                Button("清除蓝牙帧日志") {
                    BLETrace.clear()
                    bleTrace = ""
                }
                .font(.soviet(9))
                .foregroundStyle(SovietPalette.textMuted)
            }
        }
    }

    @State private var showBLETrace = false
    @State private var bleTrace = ""

    // MARK: 底部状态

    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("故障码")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
                Text(viewModel.telemetry.faultCodes.isEmpty ? "无异常" : viewModel.telemetry.faultCodes.joined(separator: " "))
                    .font(.soviet(12))
                    .foregroundStyle(viewModel.telemetry.faultCodes.isEmpty ? SovietPalette.brass : SovietPalette.redBright)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(viewModel.dataFromCache ? "本地缓存" : (viewModel.usesCloudData ? "云端上报" : "演示数据"))
                    .font(.soviet(11))
                    .foregroundStyle(viewModel.dataFromCache
                                     ? SovietPalette.brass
                                     : (viewModel.usesCloudData ? SovietPalette.ok : SovietPalette.textMuted))
                Text(Self.timeFormatter.string(from: viewModel.cacheAt ?? viewModel.telemetry.updatedAt ?? Date()))
                    .font(.soviet(12))
                    .foregroundStyle(SovietPalette.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .constructivistCard(cut: 8, borderColor: SovietPalette.black, borderWidth: 2)
        .overlay(alignment: .bottomLeading) {
            // 拉取失败必须显性化，否则用户只会看到「一直不刷新」
            if let e = viewModel.loadError {
                Text("云端拉取失败：\(e)")
                    .font(.soviet(9))
                    .foregroundStyle(SovietPalette.danger)
                    .lineLimit(2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(SovietPalette.castIron)
                    .offset(y: 2)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - 蓝牙链路状态条

private struct BLELinkRow: View {
    let session: BLESession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isReady ? SovietPalette.ok : SovietPalette.danger)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("车机蓝牙 · \(session.linkLabel)")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textSecondary)
                if let e = session.lastError, !session.isReady {
                    Text(e)
                        .font(.soviet(9))
                        .foregroundStyle(SovietPalette.danger)
                        .lineLimit(1)
                } else if let r = session.rssi {
                    Text("RSSI \(r) dBm")
                        .font(.soviet(9))
                        .foregroundStyle(SovietPalette.textFaint)
                }
            }
            Spacer()
            Button {
                Task { try? await session.connect() }
            } label: {
                Text(session.isReady ? "重连" : "连接车机")
                    .font(.soviet(11))
                    .tracking(1)
                    .foregroundStyle(SovietPalette.castIron)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SovietPalette.brass)
                    .border(SovietPalette.black, width: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .constructivistCard(cut: 6, borderColor: SovietPalette.black, borderWidth: 2)
    }
}

// MARK: - 预览

#Preview("已连接") {
    DashboardView()
}

#Preview("未连接 · 低油量") {
    var t = VehicleTelemetry.sample
    t.fuelPercent = 12
    t.batteryVoltage = 11.9
    t.lockState = .unlocked
    t.faultCodes = ["P0130"]
    return DashboardView(
        viewModel: DashboardViewModel(
            telemetry: t,
            connection: .disconnected
        )
    )
}

#Preview("扫描中") {
    DashboardView(
        viewModel: DashboardViewModel(connection: .scanning)
    )
}

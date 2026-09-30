import SwiftUI
import UIKit

// MARK: - 指令发送抽象

/// UI 层唯一的对外依赖。真实实现走 BLE / 云端，Mock 用于模拟器调试。
public protocol ControlCommandSending: Sendable {
    func send(_ action: ControlAction) async throws
}

/// 模拟发送：延迟 700ms 后成功，等价于一次蓝牙往返
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

    private let sender: any ControlCommandSending
    private let provider: (any TelemetryProvider)?
    private var pollTask: Task<Void, Never>?

    public init(
        telemetry: VehicleTelemetry = .sample,
        connection: ConnectionBadge.State = .connected(rssi: -62),
        sender: any ControlCommandSending = MockCommandSender(),
        provider: (any TelemetryProvider)? = nil
    ) {
        self.telemetry = telemetry
        self.connection = connection
        self.sender = sender
        self.provider = provider
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
        do {
            let t = try await provider.fetchTelemetry()
            telemetry = t
            connection = .connected(rssi: t.tboxSignal.map { -115 + $0 * 10 } ?? -70)
        } catch {
            connection = .disconnected
        }
    }

    @MainActor
    public func send(_ action: ControlAction) async {
        guard busyAction == nil else { return }
        busyAction = action
        defer { busyAction = nil }

        do {
            try await sender.send(action)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            banner = Banner(text: "\(action.title)已执行", isError: false)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            banner = Banner(text: "\(action.title)失败：\(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - 主界面（车辆监控站）

public struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var pendingConfirm: ControlAction?

    public init(viewModel: DashboardViewModel = DashboardViewModel()) {
        _viewModel = State(initialValue: viewModel)
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
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
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
            ConnectionBadge(state: viewModel.connection)
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
        (viewModel.telemetry.isFrontTireLow || viewModel.telemetry.isRearTireLow) ? SovietPalette.redBright : SovietPalette.brassPale
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
                        isEnabled: viewModel.isConnected
                    ) {
                        if action.needsConfirmation {
                            pendingConfirm = action
                        } else {
                            Task { await viewModel.send(action) }
                        }
                    }
                }
            }
        }
    }

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
                Text("最后上报")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
                Text(Self.timeFormatter.string(from: viewModel.telemetry.updatedAt ?? Date()))
                    .font(.soviet(12))
                    .foregroundStyle(SovietPalette.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .constructivistCard(cut: 8, borderColor: SovietPalette.black, borderWidth: 2)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
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

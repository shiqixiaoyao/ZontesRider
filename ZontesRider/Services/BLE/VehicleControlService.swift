import Foundation
import CoreBluetooth

// MARK: - 控车服务（真实 BLE 通道）
//
// 事实边界（2026-09-30 实测确认）：
//   · ifino 云端 **没有任何** REST 控车端点（sendCommand / control / lock… 全部返回
//     "No static resource xxx"），官方 H5 的 m.zontes.com/BoxApp/ashx/*.ashx 已 404。
//   · 所以控车只有两条现实路径：① 近车 BLE（本文件）② 官方签名帧（libc9x.so，未破）。
//   · 本实现走 ①：NUS 透传 + Lmfa 明文指令表（*ULoc / *UClear / *UF / *UFreeze / *RE…），
//     指令发出后等车机回 ,OK# / ,FAIL#，超时即报错——**不再有任何假成功**。
//
// 并发纪律：本类不带隔离（nonisolated），所有可变状态都在 actor（BLETransport /
// VehicleCommandChannel）内部，自己只持有 actor 引用，天然 Sendable。

public final class VehicleControlService: ControlCommandSending, @unchecked Sendable {
    public let transport: BLETransport
    public let pkeCode: String
    private let channel: VehicleCommandChannel
    private let commands: BLECommandSender

    public init(pkeCode: String, transport: BLETransport = BLETransport()) {
        self.pkeCode = pkeCode
        self.transport = transport
        let ch = VehicleCommandChannel(transport: transport, pkeCode: pkeCode)
        self.channel = ch
        self.commands = BLECommandSender(channel: ch)
    }

    /// 当前链路状态（读自 actor）
    public func currentState() async -> TransportState {
        await transport.currentState
    }

    /// 确保链路就绪：未就绪则走完整建链流程
    /// （扫描 12s → 连接 10s → 服务/特征 5s → CCCD 3s → prime 帧 "*BT,<pke>,10,001,7#"）
    public func prepare() async throws {
        if await transport.currentState == .ready { return }
        let prime = "*BT,\(pkeCode),10,001,7#"
        await transport.setPrimeFrame(prime)
        // 观测点：握手帧同样落盘（校准时要看完整帧序列）
        BLETrace.log("TX-PRIME", prime)
        try await transport.connect()
    }

    /// 发一条控车指令：先保证在线，再走明文指令表。
    /// 车机不在线 / 不回 ACK / 回 FAIL，都会如实抛错给 UI。
    public func send(_ action: ControlAction) async throws {
        try await prepare()
        try await commands.send(action)
    }

    /// 主动向车机要一次车况（*RE）
    @discardableResult
    public func refreshFromVehicle() async throws -> [String] {
        try await prepare()
        return try await channel.execute(.refresh)
    }

    /// 车机主动上报帧（*BR,1# 等）
    public var reports: AsyncStream<String> { channel.reports }

    public func disconnect() async {
        await transport.disconnect()
    }
}

// MARK: - 网关包装（给 ViewModel 用，保持 nonisolated / Sendable）

/// BLESession 是 MainActor 隔离类型（天然 Sendable），包一层即可交给 nonisolated 的 ViewModel。
public struct BLEGateway: ControlCommandSending, Sendable {
    private let session: BLESession

    public init(session: BLESession) {
        self.session = session
    }

    public func send(_ action: ControlAction) async throws {
        try await session.send(action)
    }

    public func prepare() async throws {
        try await session.connect()
    }
}

// MARK: - 蓝牙会话（UI 侧可观察）

/// @MainActor 可观察对象：把 actor 的事件流投影成 UI 状态。
/// 仪表盘靠它显示「车机蓝牙：已连接 / 扫描中 / 未连接」，并驱动控车按钮。
///
/// ⚠️ 惰性建链（v0.3.1）：**init 里绝不创建 CBCentralManager**。
/// 上一版在 RootView 的 @State 默认值里就 new 了 VehicleControlService，
/// 等于 App 冷启动第一帧就去初始化 CoreBluetooth（权限弹窗 / 蓝牙栈就绪竞争），
/// 真机上表现为「点开即闪退」。现在只有用户主动点「连接车机」或发指令时才建栈。
@Observable
@MainActor
public final class BLESession {
    public private(set) var linkState: TransportState = .idle
    public private(set) var rssi: Int?
    public private(set) var lastReport: String?
    public private(set) var lastError: String?

    private var pke: String
    private var service: VehicleControlService?
    private var eventTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?

    public init(pkeCode: String) {
        pke = pkeCode
    }

    public var pkeCode: String { pke }
    public var isReady: Bool { linkState == .ready }

    /// 换车：丢弃旧通道（pkeCode 会编进每一帧），下次用到时按新 pke 重建
    public func reconfigure(pkeCode: String) {
        guard !pkeCode.isEmpty, pkeCode != pke else { return }
        teardown()
        pke = pkeCode
        linkState = .idle
        lastError = nil
    }

    /// 惰性取服务：第一次调用才真正初始化 CoreBluetooth
    private func ensureService() -> VehicleControlService {
        if let s = service { return s }
        let s = VehicleControlService(pkeCode: pke)
        service = s
        attach(s)
        return s
    }

    private func teardown() {
        eventTask?.cancel(); eventTask = nil
        reportTask?.cancel(); reportTask = nil
        let old = service
        service = nil
        Task.detached { await old?.disconnect() }
    }

    private func attach(_ svc: VehicleControlService) {
        eventTask = Task { [weak self] in
            for await event in svc.transport.events {
                guard let self else { return }
                self.consume(event)
            }
        }
        reportTask = Task { [weak self] in
            for await text in svc.reports {
                guard let self else { return }
                self.lastReport = text
            }
        }
    }

    private func consume(_ event: TransportEvent) {
        switch event {
        case .stateChanged(let s):
            linkState = s
            if case .failed(let r) = s { lastError = r }
            if case .disconnected(let r) = s { lastError = r }
        case .rssiUpdated(let v):
            rssi = v
        case .received:
            break
        }
    }

    // MARK: 动作

    public func connect() async throws {
        let svc = ensureService()
        do {
            try await svc.prepare()
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    public func send(_ action: ControlAction) async throws {
        let svc = ensureService()
        do {
            try await svc.send(action)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    public func disconnect() async {
        guard let svc = service else { return }
        await svc.disconnect()
    }

    // MARK: 文案

    public var linkLabel: String {
        switch linkState {
        case .idle:                   return "未连接车机"
        case .scanning:               return "扫描车机…"
        case .connecting:             return "连接中…"
        case .discovering:            return "识别服务…"
        case .ready:                  return "车机在线"
        case .reconnecting(let a):    return "回连中（第 \(a) 次）"
        case .disconnected(let r):    return "已断开：\(r)"
        case .failed(let r):          return "链路故障：\(r)"
        }
    }
}

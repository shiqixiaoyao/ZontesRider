import Foundation

// MARK: - 指令通道（ACK 关键字匹配，复刻 Lxk0 的 j(ok, fail) 机制）
//
// 语义：actor 串行保证一次只飞一条指令；
// 发送前注册期望，收到 notify 文本帧后按反汇编语法判定 OK / FAIL，命中即返回。

public enum CommandError: Error, LocalizedError, Sendable {
    case vehicleRejected(String)
    case ackTimeout
    case unsupportedOnBLE(String)
    /// 没有车辆钥匙（pkeCode）：未登录 / 车辆列表没拉到 / 未选中车辆
    case noVehicleKey

    public var errorDescription: String? {
        switch self {
        case .vehicleRejected(let r):   return "车机拒绝：\(r)"
        case .ackTimeout:               return "指令超时（车机无应答）"
        case .unsupportedOnBLE(let a):  return "\(a) 不走蓝牙明文通道（需云端或签名帧）"
        case .noVehicleKey:
            return "还没拿到车辆钥匙（pkeCode）：请先在「车况」页登录并选中车辆，"
                 + "再回来连接车机。pkeCode 是每一帧的钥匙，缺它车机不会应答。"
        }
    }
}

public actor VehicleCommandChannel {
    private let transport: any TransportProtocol
    private let pkeCode: String

    /// 车机主动上报帧（*BR,1# 等），UI 可订阅做状态刷新
    public nonisolated let reports: AsyncStream<String>
    private let reportsContinuation: AsyncStream<String>.Continuation

    private var listenerTask: Task<Void, Never>?
    private var pending: CheckedContinuation<FrameVerdict, Error>?
    private var buffer = ""
    /// prime 的 ready ack 等待者（官方握手第一关，反汇编 Luk0）
    private var readyAckWaiters: [CheckedContinuation<String?, Never>] = []

    public init(transport: any TransportProtocol, pkeCode: String) {
        self.transport = transport
        self.pkeCode = pkeCode
        var cont: AsyncStream<String>.Continuation!
        reports = AsyncStream { cont = $0 }
        reportsContinuation = cont
    }

    deinit {
        listenerTask?.cancel()
        reportsContinuation.finish()
    }

    /// 执行一条明文指令，返回 OK 帧的逗号分段
    ///
    /// 超时实现：看门狗任务到点调 failPending 让挂起的等待抛错；
    /// 正常路径（ACK / 发送失败）resume 后取消看门狗。三态互斥，无泄漏。
    @discardableResult
    public func execute(_ command: PlaintextCommand, payload: String? = nil) async throws -> [String] {
        startListeningIfNeeded()

        let frame = command.frame(pkeCode: pkeCode, payload: payload)
        guard let data = frame.data(using: .utf8) else {
            throw CommandError.vehicleRejected("帧编码失败")
        }

        // 观测点：把真实发出的帧落盘（控车校准的唯一凭据）
        BLETrace.log("TX", frame)

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BLETuning.commandTimeout))
            await self?.failPending(CommandError.ackTimeout)
        }
        defer { watchdog.cancel() }

        let verdict: FrameVerdict = try await withCheckedThrowingContinuation { c in
            pending = c
            Task { [transport] in
                do {
                    try await transport.send(data)
                } catch {
                    await self.failPending(error)
                }
            }
        }

        switch verdict {
        case .ok(let fields):       return fields
        case .fail(let reason):     throw CommandError.vehicleRejected(reason)
        case .unsolicited(let t):   throw CommandError.vehicleRejected("意外上报帧：\(t)")
        case .unrelated:            throw CommandError.vehicleRejected("无法识别的应答帧")
        }
    }

    // MARK: - 握手观测（prime 的 ready ack）

    /// 等车机对 prime 帧的 ready ack（官方 ≤1200ms）。
    ///
    /// 返回收到的应答原文，超时返回 nil —— **不抛错**：
    /// 官方在没收到 ack 时也只是记一条 `"ready ack not received"` 然后继续。
    /// 我们照做，但把结果**落盘**，这样在车上点一次就能判断
    /// 「是连不上 / 是通道没被认 / 还是指令格式不对」。
    public func awaitReadyAck() async -> String? {
        startListeningIfNeeded()
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BLETuning.readyAckTimeout))
            await self?.timeoutReadyAck()
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            readyAckWaiters.append(c)
        }
    }

    private func timeoutReadyAck() {
        guard !readyAckWaiters.isEmpty else { return }
        let waiters = readyAckWaiters
        readyAckWaiters.removeAll()
        for w in waiters { w.resume(returning: nil) }
    }

    private func resolveReadyAck(with frame: String) {
        guard !readyAckWaiters.isEmpty else { return }
        let waiters = readyAckWaiters
        readyAckWaiters.removeAll()
        BLETrace.log("EVT", "ready ack: \(frame)")
        for w in waiters { w.resume(returning: frame) }
    }

    // MARK: - 收包循环

    private func startListeningIfNeeded() {
        guard listenerTask == nil else { return }
        listenerTask = Task { [weak self] in
            guard let self else { return }
            for await event in transport.events {
                if Task.isCancelled { return }
                guard case .received(let data) = event,
                      let text = String(data: data, encoding: .utf8) else { continue }
                await self.consume(text)
            }
        }
    }

    /// UART 粘包处理：按 '#' 切完整帧，残段留缓冲
    private func consume(_ chunk: String) {
        // 观测点：车机回了什么都记下来（含无法识别的帧——那正是要校准的样本）
        BLETrace.log("RX", chunk)
        buffer += chunk
        while let idx = buffer.firstIndex(of: "#") {
            let frame = String(buffer[...idx])
            buffer.removeSubrange(...idx)
            route(frame)
        }
        // 缓冲防爆：异常对端刷屏时直接清空
        if buffer.count > 4096 { buffer.removeAll() }
    }

    private func route(_ frame: String) {
        let verdict = FrameParser.verdict(of: frame)

        // ① 先让 prime 的 ready ack 认领：它是握手的应答，不该被当成某条指令的 ACK
        if !readyAckWaiters.isEmpty, FrameParser.isReadyAck(of: frame) {
            resolveReadyAck(with: frame)
            return
        }
        if case .unsolicited(let t) = verdict {
            reportsContinuation.yield(t)
            return
        }
        // ② 观测点：无法归类的帧里若有「安全响应」token（第 5 段非空），记下来。
        //    官方握手第 ④ 步就靠它，token 怎么用还没解出来，但**帧本身**是宝贵样本。
        if verdict == .unrelated, let token = FrameParser.secureToken(of: frame) {
            BLETrace.log("EVT", "secure token: \(token)")
        }
        guard let c = pending, verdict != .unrelated else { return }
        pending = nil
        c.resume(returning: verdict)
    }

    private func failPending(_ error: Error) {
        guard let c = pending else { return }
        pending = nil
        c.resume(throwing: error)
    }
}

// MARK: - ControlCommandSending 落地：UI 指令 → BLE 明文指令

/// 把仪表盘的 ControlAction 映射到 Lmfa 明文指令表。
/// ⚠️ 坐垫 / 油箱不在明文表内（那两个键走云端或签名 *BT 帧），BLE 通道直接报 unsupported。
public struct BLECommandSender: ControlCommandSending {
    private let channel: VehicleCommandChannel

    public init(channel: VehicleCommandChannel) {
        self.channel = channel
    }

    public func send(_ action: ControlAction) async throws {
        switch action {
        case .unlock:      try await channel.execute(.unlock)
        case .lock:        try await channel.execute(.lock)
        case .findVehicle: try await channel.execute(.find)
        case .arm:         try await channel.execute(.freeze)
        case .openSeat:    throw CommandError.unsupportedOnBLE(action.title)
        case .openTank:    throw CommandError.unsupportedOnBLE(action.title)
        }
    }
}

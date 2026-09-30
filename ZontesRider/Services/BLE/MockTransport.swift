import Foundation

// MARK: - Mock 传输层（无真车调试）
//
// 行为仿真（基于反编译的响应语法）：
//   connect → 模拟 扫描 0.8s + 连接 0.6s + CCCD 0.3s 后 ready
//   send    → 收到什么指令，就用同一指令字回 ",OK#" 帧；
//             *RE 额外回一帧带字段的刷新包（电压/油量/里程）
//   随机 5% 概率回 FAIL，用于验证 UI 的失败路径

public actor MockTransport: TransportProtocol {

    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    private var ready = false
    /// 置 true 可让所有指令失败（测试错误链路）
    public var alwaysFail = false
    /// 模拟网络/链路延迟
    public var latency: TimeInterval = 0.25

    public init() {
        var cont: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    deinit { continuation.finish() }

    public func connect() async throws {
        continuation.yield(.stateChanged(.scanning))
        try await sleep(0.8)
        continuation.yield(.stateChanged(.connecting))
        try await sleep(0.6)
        continuation.yield(.stateChanged(.discovering))
        try await sleep(0.3)
        ready = true
        continuation.yield(.stateChanged(.ready))
    }

    public func disconnect() async {
        ready = false
        continuation.yield(.stateChanged(.disconnected(reason: "Mock 主动断开")))
    }

    public func send(_ data: Data) async throws {
        guard ready else { throw TransportError.notReady }
        try await sleep(latency)

        guard let text = String(data: data, encoding: .utf8) else { return }
        let commandWord = text.split(separator: ",").first.map(String.init) ?? "*RE"
        let pke = text.split(separator: ",").dropFirst().first.map(String.init) ?? "864918088644768"

        if alwaysFail || Int.random(in: 1...20) == 1 {
            emit("\(commandWord),\(pke),FAIL#")
            return
        }

        switch commandWord {
        case "*RE":
            // 刷新帧：字段按 电压(132=13.2V)/油量%/里程 的顺序编排，与实测字段一致
            emit("*RE,\(pke),132,33,1265,OK#")
        case "*UF":
            emit("\(commandWord),\(pke),OK#")
            // 寻车后车机习惯补一条主动上报
            try await sleep(0.4)
            emit("*BR,1#")
        default:
            emit("\(commandWord),\(pke),OK#")
        }
    }

    private func emit(_ frame: String) {
        if let data = frame.data(using: .utf8) {
            continuation.yield(.received(data))
        }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - 一键装配：Mock 全链路（预览 / 模拟器用）

public enum MockBLEFactory {
    @MainActor
    public static func makeCommandSender(pkeCode: String = "864918088644768") -> BLECommandSender {
        let transport = MockTransport()
        let channel = VehicleCommandChannel(transport: transport, pkeCode: pkeCode)
        return BLECommandSender(channel: channel)
    }
}

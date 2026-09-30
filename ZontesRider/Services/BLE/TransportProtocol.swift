import Foundation

// MARK: - 传输层抽象
//
// 铁律：View / ViewModel 层永远不 import CoreBluetooth。
// 一切 BLE 细节收敛在 BLETransport；MockTransport 用于无真车调试。

public enum TransportEvent: Sendable {
    case stateChanged(TransportState)
    case received(Data)
    case rssiUpdated(Int)
}

public enum TransportState: Sendable, Equatable {
    case idle
    case scanning
    case connecting
    case discovering          // 服务/特征发现中
    case ready                // CCCD 已使能，可收发
    case reconnecting(attempt: Int)
    case disconnected(reason: String)
    case failed(String)
}

public enum TransportError: Error, LocalizedError, Sendable {
    case bluetoothPoweredOff
    case bluetoothUnauthorized
    case peripheralNotFound(timeout: TimeInterval)
    case connectFailed(String)
    case serviceDiscoveryTimeout
    case characteristicMissing
    case cccdEnableTimeout
    case writeTimeout
    case notReady
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .bluetoothPoweredOff:          return "蓝牙未开启"
        case .bluetoothUnauthorized:        return "蓝牙权限被拒绝"
        case .peripheralNotFound(let t):    return "扫描 \(Int(t))s 未找到车机"
        case .connectFailed(let r):         return "连接失败：\(r)"
        case .serviceDiscoveryTimeout:      return "服务发现超时（5s）"
        case .characteristicMissing:        return "NUS 特征缺失（非目标车机？）"
        case .cccdEnableTimeout:            return "订阅使能超时（3s）"
        case .writeTimeout:                 return "写入超时（900ms 无响应）"
        case .notReady:                     return "链路未就绪"
        case .cancelled:                    return "操作已取消"
        }
    }
}

/// 传输层协议：Connect → ready → send/receive → disconnect
public protocol TransportProtocol: Sendable {
    /// 事件流（状态变迁 + 收包）。多端订阅各自独立。
    var events: AsyncStream<TransportEvent> { get }

    /// 扫描并连接车机，直到进入 .ready（CCCD 使能完成）
    func connect() async throws

    /// 主动断开（不触发自动回连）
    func disconnect() async

    /// 写一帧（内部已做 180ms 节流与 900ms 写超时）
    func send(_ data: Data) async throws
}

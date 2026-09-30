import Foundation
import CoreBluetooth

// MARK: - CoreBluetooth → actor 事件桥

/// 代理回调全部发生在专属串行队列，桥对象只做一件事：把事件原样抛进 actor。
/// 桥自身不持有任何可变状态，天然无数据竞争。
enum CBEvent: Sendable {
    case poweredOn
    case poweredOff
    case unauthorized
    case discovered(CBPeripheral)
    case connected
    case connectFailed(String)
    case disconnected(String?)
    case servicesDiscovered(String?)
    case characteristicsDiscovered(CBService, String?)
    case valueReceived(CBCharacteristic)
    case valueWritten(CBCharacteristic, String?)
    case notificationStateChanged(CBCharacteristic, String?)
    case rssi(Int)
}

final class BLEDelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    let handler: @Sendable (CBEvent) -> Void

    init(handler: @escaping @Sendable (CBEvent) -> Void) {
        self.handler = handler
    }

    // MARK: Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:      handler(.poweredOn)
        case .poweredOff:     handler(.poweredOff)
        case .unauthorized:   handler(.unauthorized)
        default:              break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        handler(.discovered(peripheral))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        handler(.connected)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handler(.connectFailed(error?.localizedDescription ?? "未知原因"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handler(.disconnected(error?.localizedDescription))
    }

    // MARK: Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        handler(.servicesDiscovered(error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        handler(.characteristicsDiscovered(service, error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        handler(.valueReceived(characteristic))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        handler(.valueWritten(characteristic, error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        handler(.notificationStateChanged(characteristic, error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        handler(.rssi(RSSI.intValue))
    }
}

// MARK: - BLE 传输（actor 隔离）

/// 全生命周期状态机都关在这个 actor 里：
/// 扫描 → 连接 → 服务发现（5s）→ 特征发现 → CCCD 使能（3s）→ ready。
/// 写入强制 180ms 节流 + 900ms 写响应超时（参数全部来自反编译实锤）。
public actor BLETransport: TransportProtocol {

    // MARK: 事件流

    private let streamContinuation: AsyncStream<TransportEvent>.Continuation
    public nonisolated let events: AsyncStream<TransportEvent>

    // MARK: CoreBluetooth

    private let proxy: BLEDelegateProxy
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    // MARK: 状态

    private var state: TransportState = .idle {
        didSet { streamContinuation.yield(.stateChanged(state)) }
    }
    private var intentionalDisconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var lastWriteAt: ContinuousClock.Instant = .now

    // MARK: 等待中的 continuations（resume 前先置 nil，保证只 resume 一次）

    private var poweredOnWaiters: [CheckedContinuation<Void, Error>] = []
    private var discoveredContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var servicesContinuation: CheckedContinuation<Void, Error>?
    private var charsContinuation: CheckedContinuation<Void, Error>?
    private var cccdContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?

    public init() {
        var cont: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        streamContinuation = cont

        proxy = BLEDelegateProxy { [weak self] event in
            Task { await self?.handle(event) }
        }
        let queue = DispatchQueue(label: "com.shiqixiaoyao.zontesrider.ble", qos: .userInitiated)
        central = CBCentralManager(delegate: proxy, queue: queue, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    deinit {
        streamContinuation.finish()
    }

    // MARK: - TransportProtocol

    public func connect() async throws {
        intentionalDisconnect = false
        reconnectTask?.cancel()

        try await ensurePoweredOn()

        // 1. 扫描（优先走系统已连接列表，其次空口扫描）
        state = .scanning
        let target = try await findPeripheral()

        // 2. 连接
        state = .connecting
        peripheral = target
        target.delegate = proxy
        central.connect(target, options: nil)
        try await withTimeoutTrace(seconds: 10, error: TransportError.connectFailed("10s 超时")) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                connectContinuation = c
            }
        }

        // 3. 服务发现（反编译：5s 超时）
        state = .discovering
        target.discoverServices([VehicleGATT.service])
        try await withTimeoutTrace(seconds: BLETuning.serviceDiscoveryTimeout,
                                   error: TransportError.serviceDiscoveryTimeout) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                servicesContinuation = c
            }
        }
        guard let service = target.services?.first(where: { $0.uuid == VehicleGATT.service }) else {
            throw TransportError.characteristicMissing
        }

        // 4. 特征发现
        target.discoverCharacteristics([VehicleGATT.write, VehicleGATT.notify], for: service)
        try await withTimeoutTrace(seconds: BLETuning.serviceDiscoveryTimeout,
                                   error: TransportError.serviceDiscoveryTimeout) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                charsContinuation = c
            }
        }
        guard let w = service.characteristics?.first(where: { $0.uuid == VehicleGATT.write }),
              let n = service.characteristics?.first(where: { $0.uuid == VehicleGATT.notify }) else {
            throw TransportError.characteristicMissing
        }
        writeChar = w
        notifyChar = n

        // 5. CCCD 使能（反编译：3s 超时）
        target.setNotifyValue(true, for: n)
        try await withTimeoutTrace(seconds: BLETuning.cccdEnableTimeout,
                                   error: TransportError.cccdEnableTimeout) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                cccdContinuation = c
            }
        }

        state = .ready
    }

    public func disconnect() async {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        cleanupLink()
        state = .disconnected(reason: "主动断开")
    }

    /// 写一帧：180ms 节流（车机缓冲保护）+ withResponse + 900ms 超时
    public func send(_ data: Data) async throws {
        guard state == .ready, let p = peripheral, let w = writeChar else {
            throw TransportError.notReady
        }

        // 节流：距上一帧不足 180ms 则补齐
        let elapsed = ContinuousClock.Instant.now - lastWriteAt
        let throttle = Duration.milliseconds(Int(BLETuning.writeThrottle * 1000))
        if elapsed < throttle {
            try? await Task.sleep(for: throttle - elapsed)
        }

        try await withTimeoutTrace(seconds: BLETuning.writeAckTimeout,
                                   error: TransportError.writeTimeout) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                writeContinuation = c
                p.writeValue(data, for: w, type: .withResponse)
            }
        }
        lastWriteAt = .now
    }

    // MARK: - 事件处理（actor 内串行）

    private func handle(_ event: CBEvent) {
        switch event {
        case .poweredOn:
            for c in poweredOnWaiters { c.resume() }
            poweredOnWaiters.removeAll()

        case .poweredOff:
            failAllWaiters(TransportError.bluetoothPoweredOff)
            if case .ready = state {} else if case .idle = state {} else {
                state = .failed("蓝牙已关闭")
            }

        case .unauthorized:
            failAllWaiters(TransportError.bluetoothUnauthorized)
            state = .failed("蓝牙权限被拒绝")

        case .discovered(let p):
            central.stopScan()
            if let c = discoveredContinuation {
                discoveredContinuation = nil
                c.resume(returning: p)
            }

        case .connected:
            if let c = connectContinuation {
                connectContinuation = nil
                c.resume()
            }

        case .connectFailed(let reason):
            if let c = connectContinuation {
                connectContinuation = nil
                c.resume(throwing: TransportError.connectFailed(reason))
            }

        case .disconnected(let reason):
            let wasReady = (state == .ready)
            cleanupLink()
            failAllWaiters(TransportError.notReady)
            if intentionalDisconnect {
                state = .disconnected(reason: "主动断开")
            } else {
                state = .disconnected(reason: reason ?? "链路中断")
                if wasReady { scheduleReconnect() }
            }

        case .servicesDiscovered(let err):
            if let c = servicesContinuation {
                servicesContinuation = nil
                if let err { c.resume(throwing: TransportError.connectFailed(err)) }
                else { c.resume() }
            }

        case .characteristicsDiscovered(_, let err):
            if let c = charsContinuation {
                charsContinuation = nil
                if let err { c.resume(throwing: TransportError.connectFailed(err)) }
                else { c.resume() }
            }

        case .notificationStateChanged(let ch, let err):
            guard ch.uuid == VehicleGATT.notify else { return }
            if let c = cccdContinuation {
                cccdContinuation = nil
                if let err { c.resume(throwing: TransportError.cccdEnableTimeout) }
                else { c.resume() }
            }

        case .valueReceived(let ch):
            guard ch.uuid == VehicleGATT.notify, let data = ch.value else { return }
            streamContinuation.yield(.received(data))

        case .valueWritten(let ch, let err):
            guard ch.uuid == VehicleGATT.write else { return }
            if let c = writeContinuation {
                writeContinuation = nil
                if let err { c.resume(throwing: TransportError.connectFailed(err)) }
                else { c.resume() }
            }

        case .rssi(let v):
            streamContinuation.yield(.rssiUpdated(v))
        }
    }

    // MARK: - 内部

    private func ensurePoweredOn() async throws {
        if central.state == .poweredOn { return }
        if central.state == .unauthorized { throw TransportError.bluetoothUnauthorized }
        if central.state == .poweredOff { throw TransportError.bluetoothPoweredOff }
        try await withTimeoutTrace(seconds: 5, error: TransportError.bluetoothPoweredOff) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                poweredOnWaiters.append(c)
            }
        }
    }

    private func findPeripheral() async throws -> CBPeripheral {
        // 已 retained 的直接复用
        if let p = peripheral, p.state == .connected || p.state == .connecting { return p }
        // 系统层已连接的（其他 App 连着同一车机）
        let connected = central.retrieveConnectedPeripherals(withServices: [VehicleGATT.service])
        if let p = connected.first { return p }

        central.scanForPeripherals(withServices: [VehicleGATT.service], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
        defer { central.stopScan() }
        return try await withTimeoutTrace(seconds: 12, error: TransportError.peripheralNotFound(timeout: 12)) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
                discoveredContinuation = c
            }
        }
    }

    /// 自动回连：退避序列 [1,2,4,8,15,30]，循环到成功或主动断开
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                let delay = BLETuning.reconnectBackoff[min(attempt, BLETuning.reconnectBackoff.count - 1)]
                attempt += 1
                await self.setState(.reconnecting(attempt: attempt))
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                do {
                    try await self.connect()
                    return // 成功，connect() 内部已把 intentionalDisconnect 复位
                } catch {
                    if Task.isCancelled { return }
                    // 继续下一轮退避
                }
            }
        }
    }

    private func setState(_ s: TransportState) { state = s }

    private func cleanupLink() {
        writeChar = nil
        notifyChar = nil
    }

    private func failAllWaiters(_ error: Error) {
        for c in poweredOnWaiters { c.resume(throwing: error) }
        poweredOnWaiters.removeAll()
        discoveredContinuation?.resume(throwing: error); discoveredContinuation = nil
        connectContinuation?.resume(throwing: error); connectContinuation = nil
        servicesContinuation?.resume(throwing: error); servicesContinuation = nil
        charsContinuation?.resume(throwing: error); charsContinuation = nil
        cccdContinuation?.resume(throwing: error); cccdContinuation = nil
        writeContinuation?.resume(throwing: error); writeContinuation = nil
    }

    /// 通用超时：operation 与闹钟赛跑，输家取消
    private func withTimeoutTrace<T: Sendable>(
        seconds: TimeInterval,
        error: @autoclosure @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw error()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

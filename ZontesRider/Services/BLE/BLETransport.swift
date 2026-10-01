import Foundation
import CoreBluetooth

// MARK: - CoreBluetooth → actor 事件桥

/// 把 CBPeripheral 包一层 `@unchecked Sendable`：
/// 所有 CBCentralManager/CBPeripheral 代理回调都发生在同一个专属串行队列上，
/// 且 peripheral 对象在连接生命周期内由 CoreBluetooth 单线程管理，
/// 跨并发域传递时不会发生并发访问 —— 用 @unchecked 标注是安全且业界通行的做法。
final class PeripheralBox: @unchecked Sendable {
    let value: CBPeripheral
    init(_ p: CBPeripheral) { value = p }
}

/// 代理回调全部发生在专属串行队列，桥对象只做一件事：把事件原样抛进 actor。
/// 桥自身不持有任何可变状态，天然无数据竞争。
///
/// ⚠️ 这里**只允许携带值类型**（String / Data / Int）或 `@unchecked Sendable` 的箱子：
///    CoreBluetooth 的 CBCharacteristic / CBService / CBPeripheral / CBUUID 都是非 Sendable 的
///    ObjC 类，直接塞进 Sendable 枚举的关联值会被 Swift 6 语言模式判成 error。
///    做法：在代理这一层就把需要的字段（uuidString、value）取出来，再跨并发域传递。
enum CBEvent: Sendable {
    case poweredOn
    case poweredOff
    case unauthorized
    case discovered(PeripheralBox)
    case connected
    case connectFailed(String)
    case disconnected(String?)
    case servicesDiscovered(String?)
    case characteristicsDiscovered(String, String?)
    case valueReceived(String, Data?)
    case valueWritten(String, String?)
    case notificationStateChanged(String, String?)
    case rssi(Int)
}

final class BLEDelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    /// 两段式装配：actor init 时先建 proxy 供 CBCentralManager 使用，
    /// 全部存储属性就位后再回填 handler（闭包要 weak 捕获 self，不能提前引用）。
    var handler: (@Sendable (CBEvent) -> Void)?

    override init() {}

    // MARK: Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:      handler?(.poweredOn)
        case .poweredOff:     handler?(.poweredOff)
        case .unauthorized:   handler?(.unauthorized)
        default:              break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        handler?(.discovered(PeripheralBox(peripheral)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        handler?(.connected)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handler?(.connectFailed(error?.localizedDescription ?? "未知原因"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handler?(.disconnected(error?.localizedDescription))
    }

    // MARK: Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        handler?(.servicesDiscovered(error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        handler?(.characteristicsDiscovered(service.uuid.uuidString, error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        handler?(.valueReceived(characteristic.uuid.uuidString, characteristic.value))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        handler?(.valueWritten(characteristic.uuid.uuidString, error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        handler?(.notificationStateChanged(characteristic.uuid.uuidString, error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        handler?(.rssi(RSSI.intValue))
    }
}

// MARK: - BLE 传输（actor 隔离）

/// 全生命周期状态机都关在这个 actor 里：
/// 扫描 → 连接 → 服务发现（5s）→ 特征发现 → CCCD 使能（3s）→ ready。
/// 写入强制 180ms 节流 + 900ms 写响应超时（参数全部来自反编译实锤）。
///
/// ⚠️ 并发纪律（CI 编译器验证过的教训）：
/// continuation 的**注册**只允许出现在 actor 方法同步上下文中
/// （withCheckedThrowingContinuation 的 body 会同步继承调用方隔离）；
/// 超时一律用「看门狗 Task → actor 清理方法 resume pending」的三态互斥模式，
/// 严禁在 @Sendable 闭包里直接改 actor 属性。
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
    private var primeFrame: String?
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

        let p = BLEDelegateProxy()
        proxy = p
        let queue = DispatchQueue(label: "com.shiqixiaoyao.zontesrider.ble", qos: .userInitiated)
        central = CBCentralManager(delegate: p, queue: queue, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
        // 全部存储属性就位后再回填 handler（weak self 此时才合法）
        p.handler = { [weak self] event in
            Task { await self?.handle(event) }
        }
    }

    deinit {
        streamContinuation.finish()
    }

    // MARK: - TransportProtocol

    /// 供 UI 轮询当前链路状态（只读，actor 内访问）
    public var currentState: TransportState { state }

    // MARK: - 建链（同一时刻只允许一次）

    /// 正在进行的建链尝试。并发调用复用同一次，避免互相顶掉等待者。
    private var connectInFlight: Task<Void, Error>?

    /// 扫描 → 连接 → 服务/特征 → CCCD → prime。
    ///
    /// ⚠️ 2026-10-01 实测日志暴露的两个问题，都在这里收口：
    ///   1. 多次 `prepare()` 会各自启动一次 `connect()`，后一次把前一次等待中的
    ///      `discoveredContinuation` 顶掉（槽位只有一个）→ 状态在 scanning 反复抖动、
    ///      永远走不到 connecting。→ 加串行化，并发调用复用同一次尝试。
    ///   2. 建链失败（例如扫描 12s 超时）后**状态永久停在 .scanning**，
    ///      界面显示"一直在扫描"，日志里也没有任何失败行。→ 失败必须落到
    ///      `.failed(reason)` 并落盘。
    public func connect() async throws {
        if let inFlight = connectInFlight {
            try await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performConnect()
        }
        connectInFlight = task
        defer { connectInFlight = nil }

        do {
            try await task.value
        } catch {
            // 取消是控制流，不是故障：不标失败、不落盘
            if error is CancellationError { throw error }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            switch state {
            case .failed: break      // 已有更具体的原因（如"蓝牙已关闭"），不覆盖
            default:      state = .failed(reason)
            }
            BLETrace.log("EVT", "connect failed: \(reason)")
            throw error
        }
    }

    private func performConnect() async throws {
        intentionalDisconnect = false
        reconnectTask?.cancel()

        // 清掉上一次没走完的等待者（串行化后正常路径不会有，保险起见；
        // resume 前先置 nil，保证每个 continuation 只被 resume 一次）
        discoveredContinuation?.resume(throwing: TransportError.notReady)
        discoveredContinuation = nil
        connectContinuation?.resume(throwing: TransportError.notReady)
        connectContinuation = nil

        try await ensurePoweredOn()

        // 1. 扫描（优先系统已连接列表，其次空口扫描，12s 超时）
        state = .scanning
        let target = try await findPeripheral()

        // 2. 连接（10s 超时）
        state = .connecting
        peripheral = target
        target.delegate = proxy
        let connectWatchdog = makeWatchdog(seconds: 10) { [weak self] in
            await self?.timeoutConnect()
        }
        defer { connectWatchdog.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectContinuation = c
            central.connect(target, options: nil)
        }

        // 3. 服务发现（反编译：5s 超时）
        state = .discovering
        let svcWatchdog = makeWatchdog(seconds: BLETuning.serviceDiscoveryTimeout) { [weak self] in
            await self?.timeoutServices()
        }
        defer { svcWatchdog.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            servicesContinuation = c
            target.discoverServices([VehicleGATT.service])
        }
        guard let service = target.services?.first(where: { $0.uuid == VehicleGATT.service }) else {
            throw TransportError.characteristicMissing
        }

        // 4. 特征发现（5s 超时）
        let chrWatchdog = makeWatchdog(seconds: BLETuning.serviceDiscoveryTimeout) { [weak self] in
            await self?.timeoutChars()
        }
        defer { chrWatchdog.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            charsContinuation = c
            target.discoverCharacteristics([VehicleGATT.write, VehicleGATT.notify], for: service)
        }
        guard let w = service.characteristics?.first(where: { $0.uuid == VehicleGATT.write }),
              let n = service.characteristics?.first(where: { $0.uuid == VehicleGATT.notify }) else {
            throw TransportError.characteristicMissing
        }
        writeChar = w
        notifyChar = n

        // 5. CCCD 使能（反编译：3s 超时）
        let cccdWatchdog = makeWatchdog(seconds: BLETuning.cccdEnableTimeout) { [weak self] in
            await self?.timeoutCCCD()
        }
        defer { cccdWatchdog.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            cccdContinuation = c
            target.setNotifyValue(true, for: n)
        }

        state = .ready

        // 6. prime 帧（反编译 §2.1：就绪后先发 "*BT,<pke>,10,001,7#"，再 sleep 20ms）
        if let pf = primeFrame, let data = pf.data(using: .ascii) {
            try await write(data)
            try? await Task.sleep(for: .seconds(BLETuning.primeSettleDelay))
        }
    }

    /// 建链握手帧。控车服务在建链前写入（*BT,<pkeCode>,10,001,7#）
    public func setPrimeFrame(_ frame: String?) {
        primeFrame = frame
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
        guard state == .ready, peripheral != nil, writeChar != nil else {
            throw TransportError.notReady
        }
        try await write(data)
    }

    private func write(_ data: Data) async throws {
        guard let p = peripheral, let w = writeChar else {
            throw TransportError.notReady
        }

        // 节流：距上一帧不足 180ms 则补齐
        let elapsed = ContinuousClock.Instant.now - lastWriteAt
        let throttle = Duration.milliseconds(Int(BLETuning.writeThrottle * 1000))
        if elapsed < throttle {
            try? await Task.sleep(for: throttle - elapsed)
        }

        let watchdog = makeWatchdog(seconds: BLETuning.writeAckTimeout) { [weak self] in
            await self?.timeoutWrite()
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writeContinuation = c
            p.writeValue(data, for: w, type: .withResponse)
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
            if state != .idle {
                state = .failed("蓝牙已关闭")
            }

        case .unauthorized:
            failAllWaiters(TransportError.bluetoothUnauthorized)
            state = .failed("蓝牙权限被拒绝")

        case .discovered(let box):
            central.stopScan()
            if let c = discoveredContinuation {
                discoveredContinuation = nil
                c.resume(returning: box.value)
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

        case .notificationStateChanged(let uuidString, let err):
            guard uuidString == VehicleGATT.notify.uuidString else { return }
            if let c = cccdContinuation {
                cccdContinuation = nil
                if let err { c.resume(throwing: TransportError.cccdEnableTimeout) }
                else { c.resume() }
            }

        case .valueReceived(let uuidString, let data):
            guard uuidString == VehicleGATT.notify.uuidString, let data else { return }
            streamContinuation.yield(.received(data))

        case .valueWritten(let uuidString, let err):
            guard uuidString == VehicleGATT.write.uuidString else { return }
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
        let watchdog = makeWatchdog(seconds: 5) { [weak self] in
            await self?.timeoutPoweredOn()
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            poweredOnWaiters.append(c)
        }
    }

    private func findPeripheral() async throws -> CBPeripheral {
        // 已 retained 的直接复用
        if let p = peripheral, p.state == .connected || p.state == .connecting { return p }
        // 系统层已连接的（其他 App 连着同一车机）
        let connected = central.retrieveConnectedPeripherals(withServices: [VehicleGATT.service])
        if let p = connected.first { return p }

        let watchdog = makeWatchdog(seconds: 12) { [weak self] in
            await self?.timeoutDiscover()
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
            discoveredContinuation = c
            central.scanForPeripherals(withServices: [VehicleGATT.service], options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false,
            ])
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
                    return // 成功（connect 内部已复位 intentionalDisconnect）
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

    // MARK: 看门狗 + continuation 清理（三态互斥：事件 resume / 看门狗 resume / 主动失败 resume）

    /// 看门狗：到点在 actor 上执行清理动作（resume 对应 pending）
    private func makeWatchdog(seconds: TimeInterval,
                              _ action: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await action()
        }
    }

    private func timeoutConnect() {
        guard let c = connectContinuation else { return }
        connectContinuation = nil
        c.resume(throwing: TransportError.connectFailed("10s 超时"))
    }

    private func timeoutServices() {
        guard let c = servicesContinuation else { return }
        servicesContinuation = nil
        c.resume(throwing: TransportError.serviceDiscoveryTimeout)
    }

    private func timeoutChars() {
        guard let c = charsContinuation else { return }
        charsContinuation = nil
        c.resume(throwing: TransportError.serviceDiscoveryTimeout)
    }

    private func timeoutCCCD() {
        guard let c = cccdContinuation else { return }
        cccdContinuation = nil
        c.resume(throwing: TransportError.cccdEnableTimeout)
    }

    /// 写回调超时**不算失败**。
    /// 官方做法（反汇编原文）：`"write callback missing after 900ms; continue"` —— 记一条然后继续，
    /// 因为 onCharacteristicWrite / didWriteValueFor 在部分协议栈上本来就会漏回调。
    /// 真正的失败会由随后等待 OK#/FAIL# 的超时如实报出来，所以这里不会造成「假成功」。
    private func timeoutWrite() {
        guard let c = writeContinuation else { return }
        writeContinuation = nil
        BLETrace.log("EVT", "write callback missing after 900ms; continue")
        c.resume()
    }

    private func timeoutPoweredOn() {
        guard !poweredOnWaiters.isEmpty else { return }
        for c in poweredOnWaiters { c.resume(throwing: TransportError.bluetoothPoweredOff) }
        poweredOnWaiters.removeAll()
    }

    private func timeoutDiscover() {
        central.stopScan()
        guard let c = discoveredContinuation else { return }
        discoveredContinuation = nil
        c.resume(throwing: TransportError.peripheralNotFound(timeout: 12))
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
}

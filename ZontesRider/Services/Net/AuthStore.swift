import Foundation
import Security
import SwiftUI

// MARK: - Keychain 极简封装（免费开发者账号可用，无需 Keychain Sharing）

enum KeychainHelper {
    private static let service = "com.shiqixiaoyao.zontesrider"

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 云端链路自检（供 UI 证明「确实连着升仕后台」）

public struct CloudHealth: Sendable, Equatable {
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var lastPKECode: String?
    public var ok: Bool

    public init(lastSuccessAt: Date? = nil, lastAttemptAt: Date? = nil,
                lastError: String? = nil, lastPKECode: String? = nil, ok: Bool = false) {
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.lastPKECode = lastPKECode
        self.ok = ok
    }
}

// MARK: - 登录态仓库

/// 全局认证状态。登录成功即拉车辆列表并选中首辆（pkeCode 是后续一切车况/轨迹请求的钥匙）。
@Observable
@MainActor
public final class AuthStore {
    public enum State: Equatable {
        case loggedOut
        case loggingIn
        case loggedIn
    }

    public private(set) var state: State = .loggedOut
    public private(set) var token: String?
    private var refreshToken: String?
    public private(set) var usercode: String?
    public private(set) var vehicles: [MotorVehicle] = []

    /// 车辆列表当前是否来自本地缓存（尚未被云端刷新覆盖）
    public private(set) var vehiclesFromCache = false
    /// 本地缓存的落盘时间（「本地数据」卡片展示用）
    public private(set) var vehiclesCachedAt: Date?
    public var selectedPKECode: String? {
        didSet {
            if let selectedPKECode, !selectedPKECode.isEmpty {
                KeychainHelper.save(selectedPKECode, account: "pkeCode")
            }
        }
    }
    public var lastError: String?

    /// 云端链路自检：UI 用它回答「到底有没有接到真后台」
    public private(set) var health = CloudHealth()

    private let client = IfinoAPIClient()

    public init() {
        // 冷启动恢复会话（refreshToken 一并恢复，token 过期时才能静默续期、不掉登录）
        if let t = KeychainHelper.read(account: "accessToken"),
           let u = KeychainHelper.read(account: "usercode") {
            token = t
            refreshToken = KeychainHelper.read(account: "refreshToken")
            usercode = u
            selectedPKECode = KeychainHelper.read(account: "pkeCode")
            // 先摆上本地缓存，界面不用等网络就有车可显示（随后 refreshVehicles 覆盖）
            if let snap = LocalStore.loadVehicles(), !snap.vehicles.isEmpty {
                vehicles = snap.vehicles
                vehiclesFromCache = true
                vehiclesCachedAt = snap.fetchedAt
            }
            state = .loggedIn
            Task { await refreshVehicles() }
        }
    }

    public var isLoggedIn: Bool { state == .loggedIn && token != nil }

    public var selectedVehicle: MotorVehicle? {
        vehicles.first { $0.pkeCode == selectedPKECode } ?? vehicles.first
    }

    /// 当前可用的车辆钥匙（空串一律当无效，避免拿空 pkeCode 去请求导致“无数据”）
    public var activePKECode: String? {
        if let s = selectedPKECode, !s.isEmpty { return s }
        return vehicles.first(where: { !$0.pkeCode.isEmpty })?.pkeCode
    }

    // MARK: 登录

    public func login(usercode: String, password: String) async {
        state = .loggingIn
        lastError = nil
        do {
            let payload = try await client.login(usercode: usercode, password: password)
            token = payload.accessToken
            refreshToken = payload.refreshToken
            self.usercode = usercode
            KeychainHelper.save(payload.accessToken, account: "accessToken")
            KeychainHelper.save(usercode, account: "usercode")
            if let rt = payload.refreshToken { KeychainHelper.save(rt, account: "refreshToken") }
            state = .loggedIn
            selectedPKECode = nil
            await refreshVehicles()
        } catch {
            state = .loggedOut
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: 会话续期（保持登录状态的关键）

    /// token 过期 / 服务端返回 401 时，先用 refreshToken 静默续期。
    /// 续期成功 → 换上新的 accessToken + refreshToken，登录态不掉；
    /// 续期也失败（refreshToken 一并过期）→ 才真正退出登录。
    /// 并发安全：多个请求同时撞上 401 时，只允许一个发起续期，其余等待。
    private var refreshTask: Task<Void, Never>?

    public func ensureFreshToken() async -> Bool {
        guard refreshToken != nil || usercode != nil else { return false }
        // 已在续期中 → 等它结束
        if let t = refreshTask {
            await t.value
            return token != nil
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if let rt = self.refreshToken {
                    let p = try await self.client.refreshToken(rt)
                    self.token = p.accessToken
                    if let nrt = p.refreshToken { self.refreshToken = nrt }
                    KeychainHelper.save(p.accessToken, account: "accessToken")
                    if let nrt = p.refreshToken { KeychainHelper.save(nrt, account: "refreshToken") }
                    self.state = .loggedIn
                } else {
                    throw IfinoError.unauthorized
                }
            } catch {
                // 续期失败：清登录凭据，但**保留本地数据缓存**
                self.logout()
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
        return token != nil
    }

    // MARK: 车辆列表

    public func refreshVehicles() async { await refreshVehicles(retryAfterRefresh: true) }

    private func refreshVehicles(retryAfterRefresh: Bool) async {
        guard let token else { return }
        do {
            let list = try await client.getMyMotorList(token: token)
            vehicles = list
            if let cur = selectedPKECode, !cur.isEmpty, list.contains(where: { $0.pkeCode == cur }) {
                // 保持原选择
            } else {
                selectedPKECode = list.first?.pkeCode
            }
            lastError = nil
            health.lastPKECode = activePKECode
            // 本地留存：下次冷启动/断网也能立刻显示车辆
            if !list.isEmpty {
                LocalStore.saveVehicles(list)
                vehiclesFromCache = false
                vehiclesCachedAt = Date()
            }
        } catch let e as IfinoError {
            // 云端失败不清空已有的（缓存）车辆列表 —— 数据保留优先
            vehiclesFromCache = !vehicles.isEmpty
            if case .unauthorized = e {
                // token 过期：先静默续期，续期成功只重试一次（防无限递归）
                if retryAfterRefresh, await ensureFreshToken() {
                    await refreshVehicles(retryAfterRefresh: false)
                }
                return
            }
            lastError = e.errorDescription
            health.lastError = e.errorDescription
        } catch {
            vehiclesFromCache = !vehicles.isEmpty
            lastError = error.localizedDescription
            health.lastError = error.localizedDescription
        }
    }

    // MARK: 本地缓存读取（供 UI 冷启动先显示）

    /// 上次成功落盘的车况（含落盘时间）。返回 nil 表示这台车还没成功拉过。
    public func cachedTelemetry() -> (telemetry: VehicleTelemetry, at: Date)? {
        guard let pke = activePKECode,
              let snap = LocalStore.loadTelemetry(pke: pke) else { return nil }
        return (snap.telemetry, snap.fetchedAt)
    }

    public func cachedTrack(range: TrackRange) -> (points: [TrackPoint], at: Date)? {
        guard let pke = activePKECode else { return nil }
        return LocalStore.loadTrack(pke: pke, range: range)
    }

    /// 「本地数据」卡片数据源
    public func localCacheEntries() -> [LocalStore.Entry] { LocalStore.entries() }

    /// 只清数据缓存，不动登录态（Keychain）
    public func clearLocalCache() {
        LocalStore.clearAll()
        vehiclesFromCache = false
        vehiclesCachedAt = nil
        RawTrafficLog.clear()
    }

    // MARK: 实时车况（供 TelemetryProvider 调用）

    public func fetchHomeData() async throws -> VehicleTelemetry {
        guard let token, let pke = activePKECode else { throw IfinoError.unauthorized }
        health.lastAttemptAt = Date()
        do {
            let t = try await client.getHomeData(pkeCode: pke, token: token)
            health.lastSuccessAt = Date()
            health.lastError = nil
            health.lastPKECode = pke
            health.ok = true
            // 本地留存（用户诉求：数据要留下来，断网/解析失败时还能看到上次的车况）
            LocalStore.saveTelemetry(t, pke: pke)
            return t
        } catch let e as IfinoError {
            health.ok = false
            health.lastError = e.errorDescription
            if case .unauthorized = e {
                // 静默续期并重试一次，成功则本次请求照常返回（登录态不掉）
                if await ensureFreshToken(), let nt = token, let np = activePKECode {
                    let t = try await client.getHomeData(pkeCode: np, token: nt)
                    health.lastSuccessAt = Date()
                    health.lastError = nil
                    health.ok = true
                    LocalStore.saveTelemetry(t, pke: np)
                    return t
                }
            }
            throw e
        } catch {
            health.ok = false
            health.lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: 历史轨迹

    /// 按天切窗并发拉取；`onProgress` 每批回传一次已到手的全部点位，
    /// 让折线在 UI 上逐段长出（7 天约 10~15s，30 天约 60~70s）。
    public func fetchTrack(range: TrackRange,
                           onProgress: (@Sendable (_ points: [TrackPoint], _ doneChunks: Int) -> Void)? = nil) async throws -> [TrackPoint] {
        guard let token, let pke = activePKECode else { throw IfinoError.unauthorized }
        let (start, end) = range.window()
        do {
            let pts = try await client.getTrack(carCode: pke, startTime: start,
                                                endTime: end, token: token,
                                                onProgress: onProgress)
            health.lastSuccessAt = Date()
            health.lastError = nil
            health.ok = true
            let valid = pts.filter { $0.isValid }
            // 按档位落盘：切回「今日/近7日/近30日」时先有折线，再等存量刷新
            LocalStore.saveTrack(valid, pke: pke, range: range)
            return valid
        } catch let e as IfinoError {
            health.ok = false
            health.lastError = e.errorDescription
            if case .unauthorized = e {
                // 静默续期并重试一次（轨迹可能已按天切窗并发，这里只重试整体）
                if await ensureFreshToken(), let nt = token {
                    let pts = try await client.getTrack(carCode: pke, startTime: start,
                                                        endTime: end, token: nt,
                                                        onProgress: onProgress)
                    let valid = pts.filter { $0.isValid }
                    LocalStore.saveTrack(valid, pke: pke, range: range)
                    health.lastSuccessAt = Date()
                    health.lastError = nil
                    health.ok = true
                    return valid
                }
            }
            throw e
        } catch {
            health.ok = false
            health.lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: 退出

    /// 退出只清登录凭据（Keychain），**刻意保留本地数据缓存**：
    /// 重新登录后立刻可见上次的车况/轨迹，不用从零等一轮全量拉取。
    /// 真要清空请用 `clearLocalCache()`。
    public func logout() {
        token = nil
        refreshToken = nil
        usercode = nil
        vehicles = []
        selectedPKECode = nil
        state = .loggedOut
        health = CloudHealth()
        vehiclesFromCache = false
        vehiclesCachedAt = nil
        KeychainHelper.delete(account: "accessToken")
        KeychainHelper.delete(account: "refreshToken")
        KeychainHelper.delete(account: "usercode")
        KeychainHelper.delete(account: "pkeCode")
    }
}

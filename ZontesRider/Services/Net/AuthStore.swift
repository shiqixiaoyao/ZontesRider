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
    public private(set) var usercode: String?
    public private(set) var vehicles: [MotorVehicle] = []
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
        // 冷启动恢复会话
        if let t = KeychainHelper.read(account: "accessToken"),
           let u = KeychainHelper.read(account: "usercode") {
            token = t
            usercode = u
            selectedPKECode = KeychainHelper.read(account: "pkeCode")
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
            self.usercode = usercode
            KeychainHelper.save(payload.accessToken, account: "accessToken")
            KeychainHelper.save(usercode, account: "usercode")
            state = .loggedIn
            selectedPKECode = nil
            await refreshVehicles()
        } catch {
            state = .loggedOut
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: 车辆列表

    public func refreshVehicles() async {
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
        } catch let e as IfinoError {
            if case .unauthorized = e { logout(); return }
            lastError = e.errorDescription
            health.lastError = e.errorDescription
        } catch {
            lastError = error.localizedDescription
            health.lastError = error.localizedDescription
        }
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
            return t
        } catch let e as IfinoError {
            health.ok = false
            health.lastError = e.errorDescription
            if case .unauthorized = e { logout() }
            throw e
        } catch {
            health.ok = false
            health.lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: 历史轨迹

    public func fetchTrack(range: TrackRange) async throws -> [TrackPoint] {
        guard let token, let pke = activePKECode else { throw IfinoError.unauthorized }
        let (start, end) = range.window()
        do {
            let pts = try await client.getTrack(carCode: pke, startTime: start,
                                                endTime: end, token: token)
            health.lastSuccessAt = Date()
            health.lastError = nil
            health.ok = true
            return pts.filter { $0.isValid }
        } catch let e as IfinoError {
            health.ok = false
            health.lastError = e.errorDescription
            if case .unauthorized = e { logout() }
            throw e
        } catch {
            health.ok = false
            health.lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: 退出

    public func logout() {
        token = nil
        usercode = nil
        vehicles = []
        selectedPKECode = nil
        state = .loggedOut
        health = CloudHealth()
        KeychainHelper.delete(account: "accessToken")
        KeychainHelper.delete(account: "usercode")
        KeychainHelper.delete(account: "pkeCode")
    }
}

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

// MARK: - 登录态仓库

/// 全局认证状态。登录成功即拉车辆列表并选中首辆（pkeCode 是后续一切车况/控车请求的钥匙）。
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
            if let selectedPKECode {
                KeychainHelper.save(selectedPKECode, account: "pkeCode")
            }
        }
    }
    public var lastError: String?

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
            vehicles = try await client.getMyMotorList(token: token)
            if selectedPKECode == nil || !vehicles.contains(where: { $0.pkeCode == selectedPKECode }) {
                selectedPKECode = vehicles.first?.pkeCode
            }
        } catch let e as IfinoError {
            if case .unauthorized = e { logout(); return }
            lastError = e.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: 实时车况（供 TelemetryProvider 调用）

    public func fetchHomeData() async throws -> VehicleTelemetry {
        guard let token, let pke = selectedPKECode else { throw IfinoError.unauthorized }
        do {
            return try await client.getHomeData(pkeCode: pke, token: token)
        } catch let e as IfinoError {
            if case .unauthorized = e { logout() }
            throw e
        }
    }

    // MARK: 退出

    public func logout() {
        token = nil
        usercode = nil
        vehicles = []
        state = .loggedOut
        KeychainHelper.delete(account: "accessToken")
        KeychainHelper.delete(account: "usercode")
        KeychainHelper.delete(account: "pkeCode")
    }
}

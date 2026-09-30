import Foundation

// MARK: - ifino 云端 API 客户端
//
// 事实来源（逆向 + 实机验证，详见 _reverse/PROTOCOL-SPEC.md）：
//   BaseURL : https://www.ifino.com:8081/zontespkeapp/api   ← 必须 8081，443 不通
//   登录    : POST /auth/oauth2/token（form-urlencoded）
//             usercode / password(明文！非MD5) / grant_type=password / sys=209 / lang=CH / brand=升仕
//   鉴权头  : X-Token: <accessToken>（JWT / RS256）
//   车辆列表: GET  /pkeapp/motor/getMyMotorList?source=myList
//   实时车况: GET  /pkeapp/gx/pke/carData/getHomeData?pkeCode=<...>
//
// 响应包膜统一为 { "code": Int, "msg": String, "data": ... }，code==200 为成功。

public enum IfinoError: Error, LocalizedError, Sendable {
    case badURL
    case http(Int)
    case server(code: Int, message: String)
    case decoding(String)
    case unauthorized
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .badURL:                    return "接口地址非法"
        case .http(let c):               return "网络异常（HTTP \(c)）"
        case .server(_, let m):          return m.isEmpty ? "服务端拒绝" : m
        case .decoding(let d):           return "响应解析失败：\(d)"
        case .unauthorized:              return "登录已过期，请重新登录"
        case .network(let d):            return "网络错误：\(d)"
        }
    }
}

// MARK: 包膜

private struct Envelope<T: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: T?
}

// MARK: DTO · 登录

public struct TokenPayload: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenTime: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, tokenTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken  = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try? c.decode(String.self, forKey: .refreshToken)
        if let t = try? c.decode(Double.self, forKey: .tokenTime) { tokenTime = t }
        else if let t = try? c.decode(String.self, forKey: .tokenTime) { tokenTime = Double(t) }
        else { tokenTime = nil }
    }
}

// MARK: DTO · 车辆

public struct MotorVehicle: Decodable, Sendable, Identifiable {
    public let pkeCode: String
    public let motorName: String?
    public let motorCode: String?
    public let frameNumber: String?
    public let plateNumber: String?
    public let imsi: String?
    public let mcuID: String?
    public let serviceEndTime: String?
    public let isShowOilTankAndSeatCushion: Bool

    public var id: String { pkeCode }

    /// 展示名：优先 motorName，回落 pkeCode 尾 6 位
    public var displayName: String {
        if let n = motorName, !n.isEmpty { return n }
        return "车辆 ·\(pkeCode.suffix(6))"
    }

    enum CodingKeys: String, CodingKey {
        case pkeCode, motorName, motorCode, frameNumber, plateNumber, imsi, mcuID, serviceEndTime
        case showFlag1 = "isShowOilTankAndSeatCushion"
        case showFlag2 = "isShowTankAndSeat"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? {
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let n = try? c.decode(Int.self, forKey: k) { return String(n) }
            if let n = try? c.decode(Double.self, forKey: k) { return String(n) }
            return nil
        }
        pkeCode        = str(.pkeCode) ?? ""
        motorName      = str(.motorName)
        motorCode      = str(.motorCode)
        frameNumber    = str(.frameNumber)
        plateNumber    = str(.plateNumber)
        imsi           = str(.imsi)
        mcuID          = str(.mcuID)
        serviceEndTime = str(.serviceEndTime)
        if let b = try? c.decode(Bool.self, forKey: .showFlag1) { isShowOilTankAndSeatCushion = b }
        else { isShowOilTankAndSeatCushion = (str(.showFlag1) ?? str(.showFlag2)) == "true" }
    }
}

// MARK: - 客户端

public actor IfinoAPIClient {
    public static let baseURL = "https://www.ifino.com:8081/zontespkeapp/api"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: 登录

    /// OAuth2 密码模式。注意：新版网关密码为**明文**（非 MD5），brand 为中文「升仕」。
    public func login(usercode: String, password: String) async throws -> TokenPayload {
        let form: [(String, String)] = [
            ("usercode", usercode),
            ("password", password),
            ("grant_type", "password"),
            ("sys", "209"),
            ("lang", "CH"),
            ("brand", "升仕"),
        ]
        let data: TokenPayload = try await request(
            path: "/auth/oauth2/token", method: "POST", form: form, token: nil
        )
        return data
    }

    // MARK: 车辆列表

    public func getMyMotorList(token: String) async throws -> [MotorVehicle] {
        try await request(path: "/pkeapp/motor/getMyMotorList?source=myList",
                          method: "GET", form: nil, token: token)
    }

    // MARK: 实时车况

    public func getHomeData(pkeCode: String, token: String) async throws -> VehicleTelemetry {
        var comps = URLComponents(string: Self.baseURL + "/pkeapp/gx/pke/carData/getHomeData")
        comps?.queryItems = [URLQueryItem(name: "pkeCode", value: pkeCode)]
        guard let url = comps?.url else { throw IfinoError.badURL }
        let raw: RawTelemetry = try await perform(url: url, method: "GET", form: nil, token: token)
        return VehicleTelemetry(raw: raw)
    }

    // MARK: - 内部

    private func request<T: Decodable>(path: String, method: String,
                                       form: [(String, String)]?,
                                       token: String?) async throws -> T {
        guard let url = URL(string: Self.baseURL + path) else { throw IfinoError.badURL }
        return try await perform(url: url, method: method, form: form, token: token)
    }

    private func perform<T: Decodable>(url: URL, method: String,
                                       form: [(String, String)]?,
                                       token: String?) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = method
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("okhttp/4.9.3", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue(token, forHTTPHeaderField: "X-Token") }
        if let form {
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
            req.httpBody = form
                .map { "\($0.0)=\(Self.formEscape($0.1))" }
                .joined(separator: "&")
                .data(using: .utf8)
        }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw IfinoError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw IfinoError.network("非 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw IfinoError.unauthorized }
            throw IfinoError.http(http.statusCode)
        }

        let env: Envelope<T>
        do {
            env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw IfinoError.decoding(String(describing: error))
        }
        guard env.code == 200, let payload = env.data else {
            let code = env.code
            if code == 401 || code == 403 { throw IfinoError.unauthorized }
            throw IfinoError.server(code: code, message: env.msg ?? "")
        }
        return payload
    }

    /// application/x-www-form-urlencoded 转义（含中文 brand）
    private static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

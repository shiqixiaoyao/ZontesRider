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
//   历史轨迹: GET  /pkeapp/hbaseLocation/selectByCarCodeHbase/<carCode>?startTime=<...>&endTime=<...>
//
// 响应包膜统一为 { "code": Int, "msg": String, "data": ... }，code==200 为成功。
//
// ⚠️ 2026-09-30 实测校准（第二轮）：
//   1. getHomeData 的有效载荷在 data.myCarData 里（data 顶层只有 istate / carLocation / freezingMode）
//      —— 上一版直接把 data 当车况解码，导致所有字段为 nil，这就是「登录后无数据刷新」的根因。
//   2. 车辆列表的 PKE 字段实测是 pkecode（全小写）与 pKECode，不是 pkeCode；
//      车名 itemName、车架 cheJia、号牌 liencePlate、mcu mcuid、服务期 serviceValidTime。
//   3. 胎压额定值是 ratedFrontPressure / ratedRearPressure。

public enum IfinoError: Error, LocalizedError, Sendable {
    case badURL
    case http(Int)
    case server(code: Int, message: String)
    case decoding(String)
    case unauthorized
    case network(String)
    case noVehicle

    public var errorDescription: String? {
        switch self {
        case .badURL:                    return "接口地址非法"
        case .http(let c):               return "网络异常（HTTP \(c)）"
        case .server(_, let m):          return m.isEmpty ? "服务端拒绝" : m
        case .decoding(let d):           return "响应解析失败：\(d)"
        case .unauthorized:              return "登录已过期，请重新登录"
        case .network(let d):            return "网络错误：\(d)"
        case .noVehicle:                 return "账号下无可用车辆"
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

// MARK: DTO · 车辆（字段名按 2026-09-30 实测 JSON 校准）

public struct MotorVehicle: Decodable, Sendable, Identifiable {
    public let pkeCode: String
    public let motorName: String?      // itemName
    public let motorCode: String?      // itemCode
    public let frameNumber: String?    // cheJia
    public let plateNumber: String?    // liencePlate
    public let imsi: String?
    public let mcuID: String?          // mcuid
    public let serviceEndTime: String? // serviceValidTime
    public let isShowOilTankAndSeatCushion: Bool

    public var id: String { pkeCode }

    /// 展示名：优先 itemName，回落 pkeCode 尾 6 位
    public var displayName: String {
        if let n = motorName, !n.isEmpty { return n }
        return "车辆 ·\(pkeCode.suffix(6))"
    }

    enum CodingKeys: String, CodingKey {
        // PKE：三种大小写形态都见过，全列上
        case pkecode, pKECode, pkeCode, PKECode
        case itemName, motorTypeName, motorName
        case itemCode, motorCode
        case cheJia, frameNumber, chejia
        case liencePlate, plateNumber
        case imsi, IMSI
        case mcuid, mcuID, McuID
        case serviceValidTime, serviceEndTime
        case isShowOilTankAndSeatCushion, isShowTankAndSeat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? {
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let n = try? c.decode(Int.self, forKey: k) { return String(n) }
            if let n = try? c.decode(Double.self, forKey: k) { return String(n) }
            return nil
        }
        func first(_ keys: [CodingKeys]) -> String? {
            for k in keys { if let v = str(k), !v.isEmpty { return v } }
            return nil
        }

        pkeCode        = first([.pkecode, .pKECode, .PKECode, .pkeCode]) ?? ""
        motorName      = first([.itemName, .motorTypeName, .motorName])
        motorCode      = first([.itemCode, .motorCode])
        frameNumber    = first([.cheJia, .frameNumber, .chejia])
        plateNumber    = first([.liencePlate, .plateNumber])
        imsi           = first([.imsi, .IMSI])
        mcuID          = first([.mcuid, .mcuID, .McuID])
        serviceEndTime = first([.serviceValidTime, .serviceEndTime])
        if let b = try? c.decode(Bool.self, forKey: .isShowOilTankAndSeatCushion) {
            isShowOilTankAndSeatCushion = b
        } else {
            let s = str(.isShowOilTankAndSeatCushion) ?? str(.isShowTankAndSeat) ?? ""
            isShowOilTankAndSeatCushion = (s == "true" || s == "1")
        }
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
        let list: [MotorVehicle] = try await request(
            path: "/pkeapp/motor/getMyMotorList?source=myList",
            method: "GET", form: nil, token: token
        )
        return list.filter { !$0.pkeCode.isEmpty }
    }

    // MARK: 实时车况

    /// 实测：data = { istate, carLocation:{latitude,longitude}, myCarData:{...全部车况字段...} }
    public func getHomeData(pkeCode: String, token: String) async throws -> VehicleTelemetry {
        guard !pkeCode.isEmpty else { throw IfinoError.noVehicle }
        var comps = URLComponents(string: Self.baseURL + "/pkeapp/gx/pke/carData/getHomeData")
        comps?.queryItems = [URLQueryItem(name: "pkeCode", value: pkeCode)]
        guard let url = comps?.url else { throw IfinoError.badURL }
        let env: Envelope<HomeDataPayload> = try await perform(
            url: url, method: "GET", form: nil, token: token
        )
        guard let payload = env.data, let raw = payload.myCarData else {
            throw IfinoError.decoding("getHomeData 缺 myCarData")
        }
        return VehicleTelemetry(raw: raw, location: payload.carLocation)
    }

    // MARK: 历史轨迹（实测 2026-09-30 打通）

    /// GET /pkeapp/hbaseLocation/selectByCarCodeHbase/<carCode>?startTime=<yyyy-MM-dd HH:mm:ss>&endTime=<...>
    /// 返回 HBase 里的轨迹点：经纬度 / 时间 / 车速 / 里程 / 电压 / 锁状态
    public func getTrack(carCode: String,
                         startTime: Date,
                         endTime: Date,
                         token: String) async throws -> [TrackPoint] {
        guard !carCode.isEmpty else { throw IfinoError.noVehicle }
        let fmt = Self.backendFormatter
        var comps = URLComponents(
            string: Self.baseURL + "/pkeapp/hbaseLocation/selectByCarCodeHbase/\(carCode)"
        )
        comps?.queryItems = [
            URLQueryItem(name: "startTime", value: fmt.string(from: startTime)),
            URLQueryItem(name: "endTime", value: fmt.string(from: endTime)),
        ]
        guard let url = comps?.url else { throw IfinoError.badURL }
        let points: [TrackPoint] = try await perform(url: url, method: "GET", form: nil, token: token)
        return points
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

    /// 服务端只认 "yyyy-MM-dd HH:mm:ss"
    public static let backendFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

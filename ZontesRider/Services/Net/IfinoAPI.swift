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
//
// ⚠️ 2026-09-30 线上事故（用户报「响应解析失败：DecodingError.KeyNotFound: Key 'code'
//    not found in keyed decoding container. Path: data」）根因不在服务端，而在调用方：
//    `getHomeData` 把泛型实参写成了 `Envelope<HomeDataPayload>`，而 `perform` 自己
//    已经套了一层包膜 —— 于是实际解码的是 `Envelope<Envelope<HomeDataPayload>>`：
//    根层的 `code` 存在 → 通过；接着拿根层的 `data` 去解内层 `Envelope`，
//    内层要找 `code` → 根 data 里当然没有 → 每次必失败。车况页因此**从来没有成功过**。
//
//    教训：包膜的解开只允许发生在 `perform` / `decodePayload` 一处；
//    业务层拿到的泛型实参**永远只能是业务类型本身**。
//
// 这个包膜同时做了容错：
//   · code 允许 Int / "200" / 缺失（网关改版后不下发 code 也不会打死整条链路）
//   · msg 兼容 msg / message
//   · 内层 T 解码失败时**原样抛出**（错误信息才带得上真正的字段与路径）

private struct Envelope<T: Decodable>: Decodable {
    let code: Int?
    let msg: String?
    let data: T?

    enum CodingKeys: String, CodingKey { case code, msg, message, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int.self, forKey: .code) {
            code = i
        } else if let s = try? c.decode(String.self, forKey: .code), let i = Int(s) {
            code = i
        } else {
            code = nil
        }
        msg = (try? c.decode(String.self, forKey: .msg))
            ?? (try? c.decode(String.self, forKey: .message))
        data = try c.decodeIfPresent(T.self, forKey: .data)
    }
}

/// 轨迹按天切窗的单窗口结果（失败不抛，留给调用方决定怎么处理）
private struct ChunkResult: Sendable {
    let points: [TrackPoint]
    let error: String?
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
//
// `Codable` 的编码方向用于**本地缓存**（LocalStore）：键名写成服务端原样，
// 这样再读回来时仍旧走下面这个 `init(from:)`，字段兼容逻辑只有一份。

public struct MotorVehicle: Codable, Sendable, Identifiable {
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

    /// 编码用服务端键名（`init(from:)` 的第一优先键），保证缓存 round-trip 稳定
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pkeCode, forKey: .pkecode)
        try c.encodeIfPresent(motorName, forKey: .itemName)
        try c.encodeIfPresent(motorCode, forKey: .itemCode)
        try c.encodeIfPresent(frameNumber, forKey: .cheJia)
        try c.encodeIfPresent(plateNumber, forKey: .liencePlate)
        try c.encodeIfPresent(imsi, forKey: .imsi)
        try c.encodeIfPresent(mcuID, forKey: .mcuid)
        try c.encodeIfPresent(serviceEndTime, forKey: .serviceValidTime)
        try c.encode(isShowOilTankAndSeatCushion, forKey: .isShowOilTankAndSeatCushion)
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

    /// 用 refreshToken 换新 accessToken（2026-10-01 实测端点可用，返回同构 TokenPayload）。
    /// token 15 天过期，客户端靠它静默续期，避免把用户踢回登录页。
    public func refreshToken(_ refreshToken: String) async throws -> TokenPayload {
        let form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("sys", "209"),
            ("lang", "CH"),
            ("brand", "升仕"),
        ]
        return try await request(
            path: "/auth/oauth2/token", method: "POST", form: form, token: nil
        )
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
    ///
    /// ⚠️ 泛型实参必须是 `HomeDataPayload`（业务类型），**不能**是 `Envelope<HomeDataPayload>`：
    ///    `perform` 自己已经拆过一次包膜，再套一层就会去根的 data 里找 `code`，
    ///    必然抛 `KeyNotFound: Key 'code' ... Path: data`（2026-09-30 的真实故障）。
    public func getHomeData(pkeCode: String, token: String) async throws -> VehicleTelemetry {
        guard !pkeCode.isEmpty else { throw IfinoError.noVehicle }
        var comps = URLComponents(string: Self.baseURL + "/pkeapp/gx/pke/carData/getHomeData")
        comps?.queryItems = [URLQueryItem(name: "pkeCode", value: pkeCode)]
        guard let url = comps?.url else { throw IfinoError.badURL }
        let payload: HomeDataPayload = try await perform(
            url: url, method: "GET", form: nil, token: token
        )
        guard let raw = payload.myCarData else {
            throw IfinoError.decoding("getHomeData 的 data 里没有 myCarData（服务端未下发车况）")
        }
        return VehicleTelemetry(raw: raw, location: payload.carLocation)
    }

    // MARK: 历史轨迹（实测 2026-09-30 打通）
    //
    // ⚠️ 端点性能实测：
    //     今日   555 点 /  4.1s /  0.27 MB
    //     近 7 日 6597 点 / 64.1s /  3.18 MB
    //     近 30 日 25861 点 / 258.2s / 12.42 MB
    //   App 单请求超时 25s → 7 日、30 日**必然失败**（这就是"轨迹界面没接入"的真因）。
    //   因此这里按「1 天 1 个请求」切窗、4 路并发，并把每批结果即时回传给 UI，
    //   折线逐段长出，而不是空白等一分钟。

    /// 把时间窗切成按天的子窗口
    static func dayChunks(from start: Date, to end: Date) -> [(Date, Date)] {
        guard end > start else { return [(start, end)] }
        var out: [(Date, Date)] = []
        var cursor = start
        // 上限兜底，杜绝任何情况下的死循环
        var guardCount = 0
        while cursor < end, guardCount < 400 {
            guardCount += 1
            let next = Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? end
            if next <= cursor { break }
            out.append((cursor, min(next, end)))
            cursor = next
        }
        return out.isEmpty ? [(start, end)] : out
    }

    public func getTrack(carCode: String,
                         startTime: Date,
                         endTime: Date,
                         token: String,
                         onProgress: (@Sendable (_ points: [TrackPoint], _ doneChunks: Int) -> Void)? = nil) async throws -> [TrackPoint] {
        guard !carCode.isEmpty else { throw IfinoError.noVehicle }
        let chunks = Self.dayChunks(from: startTime, to: endTime)

        var collected: [TrackPoint] = []
        var failures: [String] = []
        let width = 4
        var index = 0
        while index < chunks.count {
            if Task.isCancelled { throw CancellationError() }
            let batch = Array(chunks[index..<min(index + width, chunks.count)])
            // 单个窗口失败（超时等）不能拖垮整页：先收下能拿到的，最后再决定是否报错
            let parts = await withTaskGroup(of: ChunkResult.self) { group -> [ChunkResult] in
                for (s, e) in batch {
                    group.addTask { [self] in
                        do {
                            let pts = try await self.fetchTrackChunk(
                                carCode: carCode, start: s, end: e, token: token
                            )
                            return ChunkResult(points: pts, error: nil)
                        } catch is CancellationError {
                            return ChunkResult(points: [], error: nil)
                        } catch {
                            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                            return ChunkResult(points: [], error: msg)
                        }
                    }
                }
                var acc: [ChunkResult] = []
                for await part in group { acc.append(part) }
                return acc
            }
            for part in parts {
                collected.append(contentsOf: part.points)
                if let e = part.error { failures.append(e) }
            }
            if Task.isCancelled { throw CancellationError() }
            // 边拉边回传：UI 可以把已到手的段落先画出来
            onProgress?(collected, min(index + batch.count, chunks.count))
            index += width
        }

        // 一个点都没拿到，且确实出过错 → 如实抛出第一个错误
        if collected.isEmpty, let first = failures.first {
            throw IfinoError.network(first)
        }

        // 排序 + 按 id 去重（相邻窗口在边界秒会重复同一点）
        let sorted = collected.sorted {
            ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast)
        }
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.id).inserted }
    }

    private func fetchTrackChunk(carCode: String, start: Date, end: Date,
                                 token: String) async throws -> [TrackPoint] {
        let fmt = Self.backendFormatter
        var comps = URLComponents(
            string: Self.baseURL + "/pkeapp/hbaseLocation/selectByCarCodeHbase/\(carCode)"
        )
        comps?.queryItems = [
            URLQueryItem(name: "startTime", value: fmt.string(from: start)),
            URLQueryItem(name: "endTime", value: fmt.string(from: end)),
        ]
        guard let url = comps?.url else { throw IfinoError.badURL }
        return try await perform(url: url, method: "GET", form: nil,
                                 token: token, timeout: 90)
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
                                       token: String?,
                                       timeout: TimeInterval = 25) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: timeout)
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
        } catch let e as URLError where e.code == .cancelled {
            // 切页 / 切档位导致的取消：向上抛 CancellationError，UI 不当成错误显示
            throw CancellationError()
        } catch {
            throw IfinoError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw IfinoError.network("非 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            RawTrafficLog.record(path: url.path, ok: false,
                                 note: "HTTP \(http.statusCode)", body: data)
            if http.statusCode == 401 || http.statusCode == 403 { throw IfinoError.unauthorized }
            throw IfinoError.http(http.statusCode)
        }

        return try Self.decodePayload(T.self, from: data, url: url)
    }

    // MARK: 包膜解析（perform 与离线自检工具共用的唯一实现）

    /// 规则（宽容度递减）：
    ///   1. 解根层包膜 `{code, msg, data}`；
    ///   2. code 允许 Int / 数字字符串 / 缺失 —— 缺失且 data 存在时按成功处理；
    ///   3. code != 200 → 服务端错误（401/403 → 登录过期）；
    ///   4. 解 data → T；
    ///   5. data 缺失/解不出 → 把整段 body 当 T 再试一次（有些接口不套包膜）。
    /// 任何失败都会：把原始响应前 1200 字写进 Documents/net-trace.log，
    /// 并把「人话版错误 + 原始片段」拼进错误文本 —— 下次不必再靠猜。
    static func decodePayload<T: Decodable>(_ type: T.Type,
                                            from data: Data,
                                            url: URL? = nil) throws -> T {
        let path = url?.path ?? "?"

        let env: Envelope<T>
        do {
            env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            let msg = shortDecodingError(error)
            RawTrafficLog.record(path: path, ok: false, note: "解析失败 \(msg)", body: data)
            throw IfinoError.decoding("\(msg)｜原始响应：\(head(data))")
        }

        if let code = env.code, code != 200 {
            RawTrafficLog.record(path: path, ok: false,
                                 note: "code=\(code) \(env.msg ?? "")", body: data)
            if code == 401 || code == 403 { throw IfinoError.unauthorized }
            throw IfinoError.server(code: code, message: env.msg ?? "")
        }

        if let payload = env.data {
            RawTrafficLog.record(path: path, ok: true)
            return payload
        }

        if let direct = try? JSONDecoder().decode(T.self, from: data) {
            RawTrafficLog.record(path: path, ok: true, note: "无包膜直解")
            return direct
        }

        RawTrafficLog.record(path: path, ok: false, note: "包膜里没有 data", body: data)
        throw IfinoError.decoding("响应里没有 data（顶层键：\(topLevelKeys(data))）｜原始响应：\(head(data))")
    }

    /// 把 DecodingError 翻成人话（保留字段名与路径 —— 这正是这次排障最缺的信息）
    public static func shortDecodingError(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "\(error)" }
        func where_(_ ctx: DecodingError.Context) -> String {
            let p = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? "根层" : p
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            return "响应缺少字段「\(key.stringValue)」（位置 \(where_(ctx))）"
        case .typeMismatch(let t, let ctx):
            return "字段类型不符，期望 \(t)（位置 \(where_(ctx))）"
        case .valueNotFound(let t, let ctx):
            return "字段是空值，期望 \(t)（位置 \(where_(ctx))）"
        case .dataCorrupted(let ctx):
            return "响应不是合法 JSON（\(ctx.debugDescription)）"
        @unknown default:
            return "未知解析错误"
        }
    }

    static func topLevelKeys(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "非 JSON 对象"
        }
        let keys = obj.keys.sorted().prefix(12)
        return keys.isEmpty ? "（空对象）" : keys.joined(separator: ",")
    }

    /// 错误信息里的原始响应片段（比日志更短，避免 UI 上糊成一片）
    static func head(_ data: Data) -> String {
        let s = RawTrafficLog.snippet(data)
        return s.count > 260 ? String(s.prefix(260)) + "…" : s
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

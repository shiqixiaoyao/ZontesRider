import Foundation

// MARK: - 本地持久化
//
// 目的（2026-09-30 用户反馈「本地数据没有保留」）：
//   App 此前只把 token / pkeCode 存进 Keychain，车况、车辆列表、轨迹**一条都不落盘**。
//   于是只要云端一次请求失败（超时、解析错误、没信号），界面就是一片 `--`，
//   用户看到的结论永远是「没数据」，而且退到后台再回来要重新等一次全量拉取。
//
// 这里做三件事：
//   1. 每次**成功**拿到数据就落盘（车辆列表 / 车况 / 轨迹按档位分开存）；
//   2. 冷启动先读盘 → 界面立刻有内容，联网成功后再覆盖（并标注「本地缓存」）；
//   3. 请求失败时保留已有缓存，界面上「错误 + 缓存数据」同时可见，而不是二选一。
//
// 全部写入都是 best-effort（`try?`），任何 IO 失败都不允许影响主流程。

// MARK: - 落盘用的快照结构

/// 车况快照（含落盘时间，UI 用来说明「这是几点缓存」）
public struct CachedTelemetry: Codable, Sendable {
    public let telemetry: VehicleTelemetry
    public let fetchedAt: Date
}

/// 车辆列表快照
public struct CachedVehicles: Codable, Sendable {
    public let vehicles: [MotorVehicle]
    public let fetchedAt: Date
}

/// 轨迹点（**已换算**的最终值，避免复用 TrackPoint 的 0.1km / 0.1V 解码口径造成二次缩小）
public struct CachedTrackPoint: Codable, Sendable {
    public let lat: Double
    public let lon: Double
    public let speed: Double?
    public let odometerKm: Double?
    public let voltage: Double?
    public let isLocked: Bool?
    public let ts: Double?

    public init(_ p: TrackPoint) {
        lat = p.latitude
        lon = p.longitude
        speed = p.speed
        odometerKm = p.odometer
        voltage = p.voltage
        isLocked = p.isLocked
        ts = p.timestamp?.timeIntervalSince1970
    }

    public var point: TrackPoint {
        TrackPoint(latitude: lat, longitude: lon, speed: speed,
                   odometer: odometerKm, voltage: voltage,
                   isLocked: isLocked,
                   timestamp: ts.map { Date(timeIntervalSince1970: $0) })
    }
}

/// 轨迹快照
public struct CachedTrack: Codable, Sendable {
    public let points: [CachedTrackPoint]
    public let fetchedAt: Date
    public let rangeKey: String
}

// MARK: - 存储

public enum LocalStore {

    /// 缓存文件超过这个点数就等距抽稀（30 天 2.5 万点 → JSON 约 3MB，
    /// 而 Canvas 侧本来就只画 1500 点，多存无益还拖慢读写）
    private static let maxCachedTrackPoints = 12_000

    public static var directory: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("ZontesRider", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static var documentsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static func url(_ name: String) -> URL? {
        directory?.appendingPathComponent(name)
    }

    // MARK: 基础读写

    public static func save<T: Encodable>(_ value: T, as name: String) {
        guard let url = url(name) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    public static func remove(_ name: String) {
        guard let url = url(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: 车辆列表

    static let vehiclesFile = "vehicles.json"

    public static func saveVehicles(_ list: [MotorVehicle]) {
        guard !list.isEmpty else { return }
        save(CachedVehicles(vehicles: list, fetchedAt: Date()), as: vehiclesFile)
    }

    public static func loadVehicles() -> CachedVehicles? {
        load(vehiclesFile, as: CachedVehicles.self)
    }

    // MARK: 车况

    static func telemetryFile(_ pke: String) -> String {
        "telemetry-\(pke.replacingOccurrences(of: "/", with: "_")).json"
    }

    public static func saveTelemetry(_ t: VehicleTelemetry, pke: String) {
        guard !pke.isEmpty else { return }
        save(CachedTelemetry(telemetry: t, fetchedAt: Date()), as: telemetryFile(pke))
    }

    public static func loadTelemetry(pke: String) -> CachedTelemetry? {
        guard !pke.isEmpty else { return nil }
        return load(telemetryFile(pke), as: CachedTelemetry.self)
    }

    // MARK: 轨迹

    static func trackFile(_ pke: String, _ range: TrackRange) -> String {
        "track-\(pke)-\(range.cacheKey).json"
    }

    public static func saveTrack(_ points: [TrackPoint], pke: String, range: TrackRange) {
        guard !pke.isEmpty, !points.isEmpty else { return }
        let thinned = decimate(points, limit: maxCachedTrackPoints)
        let snapshot = CachedTrack(points: thinned.map(CachedTrackPoint.init),
                                   fetchedAt: Date(),
                                   rangeKey: range.cacheKey)
        save(snapshot, as: trackFile(pke, range))
    }

    public static func loadTrack(pke: String, range: TrackRange) -> (points: [TrackPoint], at: Date)? {
        guard !pke.isEmpty else { return nil }
        guard let snap = load(trackFile(pke, range), as: CachedTrack.self),
              !snap.points.isEmpty else { return nil }
        return (snap.points.map(\.point), snap.fetchedAt)
    }

    /// 等距抽稀（保留首尾）
    static func decimate(_ pts: [TrackPoint], limit: Int) -> [TrackPoint] {
        guard pts.count > limit, limit > 2 else { return pts }
        let step = Double(pts.count) / Double(limit)
        var out: [TrackPoint] = []
        out.reserveCapacity(limit + 1)
        var cursor = 0.0
        while Int(cursor) < pts.count {
            out.append(pts[Int(cursor)])
            cursor += step
        }
        if let last = pts.last, out.last?.id != last.id { out.append(last) }
        return out
    }

    // MARK: 概览 / 清理（「本地数据」卡片用）

    public struct Entry: Sendable {
        public let name: String
        public let bytes: Int
        public let modifiedAt: Date?
    }

    public static func entries() -> [Entry] {
        guard let dir = directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().map { name in
            let path = dir.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
            return Entry(name: name,
                         bytes: (attrs?[.size] as? Int) ?? 0,
                         modifiedAt: attrs?[.modificationDate] as? Date)
        }
    }

    public static func totalBytes() -> Int { entries().reduce(0) { $0 + $1.bytes } }

    /// 只清数据缓存，不动 Keychain 里的登录态
    public static func clearAll() {
        guard let dir = directory else { return }
        for e in entries() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(e.name))
        }
    }
}

// MARK: - 原始报文留档（下一次出问题不用再靠猜）

/// 把每次请求的结果（状态 + 原始响应前 1200 字）追加到沙盒 Documents/net-trace.log。
/// Documents 已通过 UIFileSharingEnabled 暴露给系统「文件」App —— 用户不装 Xcode
/// 也能把这份日志导出来，这比任何「请描述一下现象」都可靠。
public enum RawTrafficLog {
    public static let fileName = "net-trace.log"
    private static let maxBytes = 48 * 1024
    private static let snippetLimit = 1200

    public static var url: URL? {
        LocalStore.documentsDirectory?.appendingPathComponent(fileName)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func record(path: String, ok: Bool, note: String = "", body: Data? = nil) {
        // 离线自检（Tools/decode_check）不希望往真实 Documents 里写字，用环境变量关掉
        if ProcessInfo.processInfo.environment["ZR_TRACE_OFF"] == "1" { return }
        guard let url else { return }
        var line = "[\(stamp.string(from: Date()))] \(ok ? "OK " : "ERR") \(path)"
        if !note.isEmpty { line += " | \(note)" }
        if let body, !body.isEmpty { line += " | " + snippet(body) }
        line += "\n"

        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += line
        if text.utf8.count > maxBytes {
            text = "[…已截断，只留最近记录…]\n" + String(text.suffix(maxBytes / 2))
        }
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    public static func tail(limit: Int = 1600) -> String {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.count > limit ? String(text.suffix(limit)) : text
    }

    public static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 单行化 + 截断，避免一条 HTML/超长报文把日志刷爆
    static func snippet(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)
            ?? String(decoding: data.prefix(snippetLimit), as: UTF8.self)
        let flat = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return flat.count > snippetLimit ? String(flat.prefix(snippetLimit)) + "…" : flat
    }
}

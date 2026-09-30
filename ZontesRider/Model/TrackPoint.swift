import Foundation

// MARK: - 云端轨迹点
//
// 端点（2026-09-30 实测打通）：
//   GET /pkeapp/hbaseLocation/selectByCarCodeHbase/<carCode>?startTime=<yyyy-MM-dd HH:mm:ss>&endTime=<...>
// 实测样本字段：
//   {"odomileages":11240,"carCode":"864918088644768","latitude":28.5546066895,
//    "longitude":107.4507038528,"lock":1,"speed":0,"voltage":131,
//    "time":"2026-09-23 21:04:11","createTime":"2026-09-23 21:04:11"}

public struct TrackPoint: Decodable, Sendable, Equatable, Identifiable {
    public let latitude: Double
    public let longitude: Double
    public let speed: Double?        // km/h
    public let odometer: Double?     // km（服务端原始值）
    public let voltage: Double?      // 131 → 13.1V
    public let isLocked: Bool?
    public let timestamp: Date?

    public var id: String {
        "\(latitude),\(longitude),\(timestamp?.timeIntervalSince1970 ?? 0)"
    }

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, speed, voltage, lock, time, createTime
        case odomileages, oDOMileages, ODOMileages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func dbl(_ keys: [CodingKeys]) -> Double? {
            for k in keys {
                if let v = try? c.decode(Double.self, forKey: k) { return v }
                if let s = try? c.decode(String.self, forKey: k), let v = Double(s) { return v }
                if let i = try? c.decode(Int.self, forKey: k) { return Double(i) }
            }
            return nil
        }
        func str(_ keys: [CodingKeys]) -> String? {
            for k in keys { if let v = try? c.decode(String.self, forKey: k) { return v } }
            return nil
        }

        latitude  = dbl([.latitude]) ?? 0
        longitude = dbl([.longitude]) ?? 0
        speed     = dbl([.speed])
        odometer  = dbl([.odomileages, .oDOMileages, .ODOMileages])
        voltage   = dbl([.voltage]).map { $0 / 10 }
        if let i = try? c.decode(Int.self, forKey: .lock) { isLocked = (i == 1) }
        else if let s = str([.lock]) { isLocked = (s == "1" || s == "true") }
        else { isLocked = nil }
        timestamp = TrackPoint.parse(str([.time, .createTime]))
    }

    public init(latitude: Double, longitude: Double, speed: Double?,
                odometer: Double?, voltage: Double?, isLocked: Bool?, timestamp: Date?) {
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.odometer = odometer
        self.voltage = voltage
        self.isLocked = isLocked
        self.timestamp = timestamp
    }

    public var isValid: Bool { latitude != 0 && longitude != 0 }

    private static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - 轨迹统计

public struct TrackStats: Sendable, Equatable {
    public let pointCount: Int
    public let distanceKm: Double      // 按 Haversine 累加
    public let durationMinutes: Double
    public let maxSpeed: Double
    public let avgSpeed: Double
    public let odometerDelta: Double?  // 首末里程差（服务端口径）

    public init(points: [TrackPoint]) {
        let valid = points.filter { $0.isValid }
        pointCount = valid.count

        var dist = 0.0
        for i in 1..<valid.count {
            dist += TrackStats.haversine(
                lat1: valid[i - 1].latitude, lon1: valid[i - 1].longitude,
                lat2: valid[i].latitude, lon2: valid[i].longitude
            )
        }
        distanceKm = dist

        let times = valid.compactMap { $0.timestamp }.sorted()
        if let first = times.first, let last = times.last, last > first {
            durationMinutes = last.timeIntervalSince(first) / 60
        } else {
            durationMinutes = 0
        }

        let speeds = valid.compactMap { $0.speed }.filter { $0 >= 0 && $0 < 1000 }
        maxSpeed = speeds.max() ?? 0
        avgSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)

        let odos = valid.compactMap { $0.odometer }
        if let first = odos.first, let last = odos.last, last >= first {
            odometerDelta = last - first
        } else {
            odometerDelta = nil
        }
    }

    public static let empty = TrackStats(points: [])

    /// 两点球面距离（km）
    public static func haversine(lat1: Double, lon1: Double,
                                 lat2: Double, lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

// MARK: - 时间范围档位

public enum TrackRange: String, CaseIterable, Sendable, Identifiable {
    case today = "今日"
    case week = "近 7 日"
    case month = "近 30 日"

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    public func window(from now: Date = Date()) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let start: Date
        if self == .today {
            start = cal.startOfDay(for: now)
        } else {
            start = cal.date(byAdding: .day, value: -days, to: now) ?? now
        }
        return (start, now)
    }
}

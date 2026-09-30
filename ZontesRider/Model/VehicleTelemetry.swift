import Foundation

// MARK: - 云端原始报文
//
// ⚠️ 2026-09-30 实测校准：getHomeData 的车况字段全部在 `data.myCarData` 内，
// 且服务端字段名大小写混用（pkecode / pKECode、gsmrssi / gSMRSSI、odomileages / oDOMileages），
// 这里把见过的形态全列上，服务端改版只改本结构，UI 层不动。

/// getHomeData 的 data 层：车况在 myCarData，定位在 carLocation
public struct HomeDataPayload: Decodable, Sendable {
    public let myCarData: RawTelemetry?
    public let carLocation: VehicleLocation?
    public let freezingMode: String?
    public let chaseMode: String?

    enum CodingKeys: String, CodingKey {
        case myCarData, MyCarData
        case carLocation, CarLocation
        case freezingMode, chaseMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        myCarData = (try? c.decode(RawTelemetry.self, forKey: .myCarData))
            ?? (try? c.decode(RawTelemetry.self, forKey: .MyCarData))
        carLocation = (try? c.decode(VehicleLocation.self, forKey: .carLocation))
            ?? (try? c.decode(VehicleLocation.self, forKey: .CarLocation))
        freezingMode = (try? c.decode(String.self, forKey: .freezingMode))
        chaseMode = (try? c.decode(String.self, forKey: .chaseMode))
    }
}

/// 车辆定位（data.carLocation）
public struct VehicleLocation: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    enum CodingKeys: String, CodingKey { case latitude, longitude }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func dbl(_ k: CodingKeys) -> Double? {
            if let v = try? c.decode(Double.self, forKey: k) { return v }
            if let s = try? c.decode(String.self, forKey: k), let v = Double(s) { return v }
            return nil
        }
        latitude = dbl(.latitude) ?? 0
        longitude = dbl(.longitude) ?? 0
    }

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool { latitude != 0 && longitude != 0 }
}

public struct RawTelemetry: Decodable {
    public let pkeCode: String?
    public let motorName: String?
    public let voltage: Int?          // 132  → 13.2 V
    public let oil: Int?              // 33   → 33 %
    public let range: Int?            // 128  km
    public let totalMileage: Double?  // 1275.0 km
    public let speed: Double?         // 4000000 = 哨兵值，表示无效
    public let frontTire: Int?
    public let rearTire: Int?
    public let frontTireRate: Int?
    public let rearTireRate: Int?
    public let satellite: Int?
    public let tboxSignal: Int?
    public let lockState: Int?
    public let faultCode: String?
    public let changeTime: String?
    public let freezingMode: String?
    public let latitude: Double?
    public let longitude: Double?
    public let isShowOilTankAndSeatCushion: Bool?

    /// 服务端在无有效数据时下发的哨兵值（2026-09-30 实测到 1000000；
    /// 更早的接口版本下发过 4000000），UI 必须过滤，否则会显示成百万车速
    public static let speedSentinels: [Double] = [1_000_000, 4_000_000]

    /// 摩托车的合理车速上限（km/h）：超过一律视为无效数据
    public static let maxPlausibleSpeed: Double = 400

    public static func sanitizeSpeed(_ v: Double?) -> Double? {
        guard let v, v >= 0, v <= maxPlausibleSpeed else { return nil }
        return speedSentinels.contains(v) ? nil : v
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RawTelemetry.CodingKeys.self)

        func int(_ keys: [CodingKeys]) -> Int? {
            for k in keys {
                if let v = try? c.decode(Int.self, forKey: k) { return v }
                if let s = try? c.decode(String.self, forKey: k), let v = Int(s) { return v }
                if let d = try? c.decode(Double.self, forKey: k) { return Int(d) }
            }
            return nil
        }
        func dbl(_ keys: [CodingKeys]) -> Double? {
            for k in keys {
                if let v = try? c.decode(Double.self, forKey: k) { return v }
                if let s = try? c.decode(String.self, forKey: k), let v = Double(s) { return v }
            }
            return nil
        }
        func str(_ keys: [CodingKeys]) -> String? {
            for k in keys { if let v = try? c.decode(String.self, forKey: k) { return v } }
            return nil
        }

        pkeCode     = str([.pkecode, .pKECode, .PKECode, .pkeCode, .carCode])
        motorName   = str([.itemName, .motorTypeName, .motorName])
        voltage     = int([.voltage, .Voltage])
        oil         = int([.oil, .Oil, .oilPercent])
        range       = int([.range, .Range])
        totalMileage = dbl([.odomileages, .oDOMileages, .ODOMileages, .totalMileage])
        speed       = dbl([.speed, .Speed])
        frontTire   = int([.pressureFront, .pressurefront])
        rearTire    = int([.pressureRear, .pressurerear])
        frontTireRate = int([.ratedFrontPressure, .productsRatedFront, .frontRated])
        rearTireRate  = int([.ratedRearPressure, .productsRatedRear, .rearRated])
        satellite   = int([.satelliteNum, .satellite])
        tboxSignal  = int([.gsmrssi, .gSMRSSI, .tboxSignal])
        lockState   = int([.lock, .Lock, .lockState])
        faultCode   = str([.faultCode, .FaultCode])
        changeTime  = str([.changeTime, .ChangeTime])
        freezingMode = str([.freezingMode, .FreezingMode])
        latitude    = dbl([.latitude])
        longitude   = dbl([.longitude])
        isShowOilTankAndSeatCushion = (try? c.decode(Bool.self, forKey: .isShowOilTankAndSeatCushion))
            ?? (str([.isShowOilTankAndSeatCushion, .tankFlag])?.boolValue)
    }

    enum CodingKeys: String, CodingKey {
        case pkecode, pKECode, PKECode, pkeCode, carCode
        case itemName, motorTypeName, motorName
        case voltage, Voltage
        case oil, Oil, oilPercent
        case range, Range
        case odomileages, oDOMileages, ODOMileages, totalMileage
        case speed, Speed
        case pressureFront, pressurefront
        case pressureRear, pressurerear
        case ratedFrontPressure, productsRatedFront, frontRated
        case ratedRearPressure, productsRatedRear, rearRated
        case satelliteNum, satellite
        case gsmrssi, gSMRSSI, tboxSignal
        case lock, Lock, lockState
        case faultCode, FaultCode
        case changeTime, ChangeTime
        case freezingMode, FreezingMode
        case latitude, longitude
        case isShowOilTankAndSeatCushion, tankFlag = "isShowOilTankAndSeatCushionFlag"
    }
}

private extension String {
    var boolValue: Bool? {
        switch lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }
}

// MARK: - UI 展示模型

/// `Codable` 是给**本地持久化**用的（LocalStore）：车况成功一次就落盘，
/// 之后冷启动/断网都能先把上次的车况摆出来，而不是一屏 `--`。
public struct VehicleTelemetry: Codable, Sendable, Equatable {
    public var pkeCode: String
    public var displayName: String
    public var variant: String

    public var batteryVoltage: Double?    // V，已 ÷10
    public var fuelPercent: Int?
    public var rangeKm: Int?
    public var odometerKm: Double?
    public var speedKmh: Double?          // 已过滤哨兵值

    public var frontTireKpa: Int?
    public var rearTireKpa: Int?
    public var frontTireRated: Int?
    public var rearTireRated: Int?

    public var satelliteCount: Int?
    public var tboxSignal: Int?

    public var lockState: LockState
    public var faultCodes: [String]
    public var supportsSeatAndTank: Bool
    public var isFrozen: Bool

    public var location: VehicleLocation?
    public var updatedAt: Date?

    public enum LockState: Int, Codable, Sendable {
        case unknown = -1
        case unlocked = 0
        case locked = 1
        case armed = 2

        var label: String {
            switch self {
            case .unknown: return "未知"
            case .unlocked: return "未上锁"
            case .locked: return "已上锁"
            case .armed: return "已设防"
            }
        }
    }

    public init(
        pkeCode: String = "",
        displayName: String = "升仕 175V",
        variant: String = "国Ⅳ · 2026 · 特黑",
        batteryVoltage: Double? = nil,
        fuelPercent: Int? = nil,
        rangeKm: Int? = nil,
        odometerKm: Double? = nil,
        speedKmh: Double? = nil,
        frontTireKpa: Int? = nil,
        rearTireKpa: Int? = nil,
        frontTireRated: Int? = nil,
        rearTireRated: Int? = nil,
        satelliteCount: Int? = nil,
        tboxSignal: Int? = nil,
        lockState: LockState = .unknown,
        faultCodes: [String] = [],
        supportsSeatAndTank: Bool = true,
        isFrozen: Bool = false,
        location: VehicleLocation? = nil,
        updatedAt: Date? = nil
    ) {
        self.pkeCode = pkeCode
        self.displayName = displayName
        self.variant = variant
        self.batteryVoltage = batteryVoltage
        self.fuelPercent = fuelPercent
        self.rangeKm = rangeKm
        self.odometerKm = odometerKm
        self.speedKmh = speedKmh
        self.frontTireKpa = frontTireKpa
        self.rearTireKpa = rearTireKpa
        self.frontTireRated = frontTireRated
        self.rearTireRated = rearTireRated
        self.satelliteCount = satelliteCount
        self.tboxSignal = tboxSignal
        self.lockState = lockState
        self.faultCodes = faultCodes
        self.supportsSeatAndTank = supportsSeatAndTank
        self.isFrozen = isFrozen
        self.location = location
        self.updatedAt = updatedAt
    }

    public init(raw: RawTelemetry, location: VehicleLocation? = nil) {
        let loc = location ?? RawTelemetry.makeLocation(lat: raw.latitude, lon: raw.longitude)
        self.init(
            pkeCode: raw.pkeCode ?? "",
            displayName: raw.motorName ?? "升仕",
            variant: "",
            batteryVoltage: raw.voltage.map { Double($0) / 10 },
            fuelPercent: raw.oil,
            rangeKm: raw.range,
            odometerKm: raw.totalMileage,
            speedKmh: RawTelemetry.sanitizeSpeed(raw.speed),
            frontTireKpa: raw.frontTire,
            rearTireKpa: raw.rearTire,
            frontTireRated: raw.frontTireRate,
            rearTireRated: raw.rearTireRate,
            satelliteCount: raw.satellite,
            tboxSignal: raw.tboxSignal,
            lockState: raw.lockState.flatMap { LockState(rawValue: $0) } ?? .unknown,
            faultCodes: (raw.faultCode ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            supportsSeatAndTank: raw.isShowOilTankAndSeatCushion ?? false,
            isFrozen: (raw.freezingMode ?? "") == "1",
            location: loc,
            updatedAt: raw.changeTime.map { Self.parse($0) } ?? nil
        )
    }

    // MARK: 派生状态

    /// 电压低于 12.4V 视为亏电
    public var isBatteryLow: Bool { (batteryVoltage ?? 99) < 12.4 }

    /// 油量低于 20% 提示
    public var isFuelLow: Bool { (fuelPercent ?? 100) < 20 }

    /// 胎压低于额定值 80% 视为告警
    public var isFrontTireLow: Bool {
        guard let a = frontTireKpa, let r = frontTireRated, r > 0 else { return false }
        return Double(a) < Double(r) * 0.8
    }

    public var isRearTireLow: Bool {
        guard let a = rearTireKpa, let r = rearTireRated, r > 0 else { return false }
        return Double(a) < Double(r) * 0.8
    }

    public var voltageRatio: Double {
        // 11.5V ~ 14.8V 映射到 0...1
        guard let v = batteryVoltage else { return 0 }
        return min(max((v - 11.5) / (14.8 - 11.5), 0), 1)
    }

    public var coordinateText: String? {
        guard let l = location, l.isValid else { return nil }
        return String(format: "%.5f, %.5f", l.latitude, l.longitude)
    }

    private static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

private extension RawTelemetry {
    static func makeLocation(lat: Double?, lon: Double?) -> VehicleLocation? {
        guard let lat, let lon, lat != 0, lon != 0 else { return nil }
        return VehicleLocation(latitude: lat, longitude: lon)
    }
}

// MARK: - 预览样本（真实车况）

public extension VehicleTelemetry {
    static let sample = VehicleTelemetry(
        pkeCode: "864918088644768",
        displayName: "175V特黑（国Ⅳ）",
        variant: "国Ⅳ · 2026 · 特黑",
        batteryVoltage: 13.2,
        fuelPercent: 33,
        rangeKm: 128,
        odometerKm: 1275.0,
        speedKmh: nil,
        frontTireKpa: 93,
        rearTireKpa: 111,
        frontTireRated: 195,
        rearTireRated: 230,
        satelliteCount: 29,
        tboxSignal: 5,
        lockState: .unlocked,
        faultCodes: [],
        supportsSeatAndTank: true,
        isFrozen: false,
        location: VehicleLocation(latitude: 28.5545, longitude: 107.4508),
        updatedAt: Date()
    )
}

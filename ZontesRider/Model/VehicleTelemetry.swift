import Foundation

// MARK: - 云端原始报文

/// getHomeData 返回的原始字段。
/// ⚠️ 字段名按实测 JSON 校准过一轮，若服务端改版只改本结构，UI 层不动。
public struct RawTelemetry: Decodable {
    public let pkeCode: String?
    public let motorName: String?
    public let voltage: Int?          // 132  → 13.2 V
    public let oil: Int?              // 33   → 33 %
    public let range: Int?            // 128  km
    public let totalMileage: Double?  // 1265.0 km
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
    public let isShowOilTankAndSeatCushion: Bool?

    /// 服务端在无有效数据时下发的哨兵值，UI 必须过滤，否则会显示成 400 万
    public static let speedSentinel: Double = 4_000_000

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RawTelemetry.CodingKeys.self)

        func int(_ keys: [CodingKeys]) -> Int? {
            for k in keys {
                if let v = try? c.decode(Int.self, forKey: k) { return v }
                if let s = try? c.decode(String.self, forKey: k), let v = Int(s) { return v }
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

        pkeCode     = str([.pkeCode, .pkeCodeAlt])
        motorName   = str([.motorName, .motorNameAlt])
        voltage     = int([.voltage, .voltageAlt])
        oil         = int([.oil, .oilAlt, .oilPercent])
        range       = int([.range, .rangeAlt])
        totalMileage = dbl([.totalMileage, .totalMileageAlt])
        speed       = dbl([.speed, .speedAlt])
        frontTire   = int([.frontTire, .frontTireAlt])
        rearTire    = int([.rearTire, .rearTireAlt])
        frontTireRate = int([.frontTireRate, .frontTireRateAlt])
        rearTireRate  = int([.rearTireRate, .rearTireRateAlt])
        satellite   = int([.satellite, .satelliteAlt])
        tboxSignal  = int([.tboxSignal, .tboxSignalAlt])
        lockState   = int([.lockState, .lockStateAlt])
        faultCode   = str([.faultCode, .faultCodeAlt])
        changeTime  = str([.changeTime, .changeTimeAlt])
        isShowOilTankAndSeatCushion = (try? c.decode(Bool.self, forKey: .isShowOilTankAndSeatCushion))
            ?? (str([.isShowOilTankAndSeatCushion, .tankFlag])?.boolValue)
    }

    enum CodingKeys: String, CodingKey {
        case pkeCode, pkeCodeAlt = "PKECode"
        case motorName, motorNameAlt = "motorTypeName"
        case voltage, voltageAlt = "Voltage"
        case oil, oilAlt = "Oil", oilPercent = "oilPercent"
        case range, rangeAlt = "Range"
        case totalMileage, totalMileageAlt = "odomileages"
        case speed, speedAlt = "Speed"
        case frontTire, frontTireAlt = "pressureFront"
        case rearTire, rearTireAlt = "pressureRear"
        case frontTireRate, frontTireRateAlt = "frontRated"
        case rearTireRate, rearTireRateAlt = "rearRated"
        case satellite, satelliteAlt = "satelliteNum"
        case tboxSignal, tboxSignalAlt = "gsmrssi"
        case lockState, lockStateAlt = "lock"
        case faultCode, faultCodeAlt = "FaultCode"
        case changeTime, changeTimeAlt = "ChangeTime"
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

public struct VehicleTelemetry: Sendable, Equatable {
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

    public var updatedAt: Date?

    public enum LockState: Int, Sendable {
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
        self.updatedAt = updatedAt
    }

    public init(raw: RawTelemetry) {
        self.init(
            pkeCode: raw.pkeCode ?? "",
            displayName: raw.motorName ?? "升仕",
            variant: "",
            batteryVoltage: raw.voltage.map { Double($0) / 10 },
            fuelPercent: raw.oil,
            rangeKm: raw.range,
            odometerKm: raw.totalMileage,
            speedKmh: raw.speed.flatMap { $0 >= RawTelemetry.speedSentinel ? nil : $0 },
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

// MARK: - 预览样本（真实车况）

public extension VehicleTelemetry {
    static let sample = VehicleTelemetry(
        pkeCode: "864918088644768",
        displayName: "升仕 175V",
        variant: "国Ⅳ · 2026 · 特黑",
        batteryVoltage: 13.2,
        fuelPercent: 33,
        rangeKm: 128,
        odometerKm: 1265.0,
        speedKmh: nil,
        frontTireKpa: 93,
        rearTireKpa: 112,
        frontTireRated: 195,
        rearTireRated: 230,
        satelliteCount: 31,
        tboxSignal: 5,
        lockState: .armed,
        faultCodes: [],
        supportsSeatAndTank: true,
        updatedAt: Date()
    )
}

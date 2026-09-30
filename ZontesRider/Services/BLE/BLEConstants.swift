import Foundation
import CoreBluetooth

// MARK: - BLE 常量（全部来自逆向实锤，见 _reverse/PROTOCOL-SPEC.md）
//
// GATT 拓扑 = Nordic UART Service（双源验证：ShiRide 的 Lxk0 + 官方 msbox 的 uart.UARTService）

public enum VehicleGATT {
    public static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let write   = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let notify  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let cccd    = CBUUID(string: "00002902-0000-1000-8000-00805F9B34FB")
}

/// 时序参数：逐条来自 ShiRide 反汇编（Lxk0），不要凭感觉改
public enum BLETuning {
    /// 服务发现超时（反编译：5s）
    public static let serviceDiscoveryTimeout: TimeInterval = 5
    /// CCCD 使能超时（反编译：3s）
    public static let cccdEnableTimeout: TimeInterval = 3
    /// 单帧写入等待对端 ACK 的超时（反编译：900ms）
    public static let writeAckTimeout: TimeInterval = 0.9
    /// 写后强制节流（反编译：sleep 180ms，车机侧缓冲处理不过来会丢帧）
    public static let writeThrottle: TimeInterval = 0.18
    /// 连接后首帧（prime）之后的稳定等待（反编译：20ms）
    public static let primeSettleDelay: TimeInterval = 0.02
    /// 指令级总超时（等待 OK/FAIL 关键字）
    public static let commandTimeout: TimeInterval = 6
    /// 断连后自动回连的退避序列
    public static let reconnectBackoff: [TimeInterval] = [1, 2, 4, 8, 15, 30]
}

// MARK: - 明文指令表（Lmfa 反汇编实锤，9 个 case 的 Java hashCode 逐一验算过）
//
// 响应语法（硬证据 regionMatches ",OK#"）：
//   成功 → *XX,<f1>,...,<fn>,OK#      失败 → *XX,...,FAIL# 或首段 "0#"
//   *BR,1# 为车机主动上报帧，不是任何指令的响应

public enum PlaintextCommand: String, Sendable, CaseIterable {
    case refresh  = "*RE"      // 刷新车况
    case unlock   = "*UClear"  // 解锁
    case lock     = "*ULoc"    // 上锁
    case find     = "*UF"      // 寻车
    case freeze   = "*UFreeze" // 冻结（设防）
    case unfreeze = "*AC"      // 解冻（撤防），+ 功能码
    case untrack  = "*UChase"  // 取消追踪
    case diagnose = "*UKEY"    // 诊断

    /// 组帧。⚠️ 载荷段格式待真车抓包终验——目前按响应语法对称构造。
    /// 抓到 HCI 日志后只需改这一个方法。
    public func frame(pkeCode: String, payload: String? = nil) -> String {
        if let payload, !payload.isEmpty {
            return "\(rawValue),\(pkeCode),\(payload)#"
        }
        return "\(rawValue),\(pkeCode)#"
    }
}

// MARK: - 响应判定

public enum FrameVerdict: Sendable, Equatable {
    case ok(fields: [String])
    case fail(reason: String)
    case unsolicited(String)   // *BR,1# 等车机主动帧
    case unrelated
}

public enum FrameParser {
    /// 按反汇编语法判定一帧：split(",") → 首段 "0#" 失败；尾段 ",OK#" 成功；"FAIL" 失败；*BR 主动上报
    public static func verdict(of text: String) -> FrameVerdict {
        if text.hasPrefix("*BR") { return .unsolicited(text) }
        let fields = text
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .components(separatedBy: ",")
        if let first = fields.first, first == "0" || first == "0#" {
            return .fail(reason: "车机返回失败帧（首段 0#）")
        }
        if text.contains("FAIL") {
            return .fail(reason: "车机返回 FAIL")
        }
        if text.hasSuffix(",OK#") || text.hasSuffix("OK#") {
            return .ok(fields: fields)
        }
        return .unrelated
    }
}

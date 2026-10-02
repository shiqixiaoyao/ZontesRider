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

/// 时序参数：逐条来自 ShiRide 反汇编（Lxk0 / Luk0 / Lvk0），不要凭感觉改
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

    // MARK: 扫描（两段式）

    /// 阶段 1：按 NUS 服务 UUID 过滤扫（精准，快）
    public static let scanPhase1Timeout: TimeInterval = 6
    /// 阶段 2：不过滤全扫 + 逐个候选落盘再挑。
    /// 依据：官方 Android 端（Lmk0）是靠**设备名 / 厂商数据 / 已记住的 MAC 地址**找车机的，
    /// 重连更是直接 `ScanFilter.setDeviceAddress(...)` —— 说明车机广播里可能压根不带 NUS 服务 UUID。
    /// iOS 拿不到 MAC，只能全扫后按广播内容 + 信号强度挑。
    public static let scanPhase2Timeout: TimeInterval = 8

    // MARK: 控制通道握手时序（Luk0.a / Lvk0.a 反汇编实锤，2026-10-01 补挖）

    /// prime 帧后等车机 ready ack（反编译：Luk0 里 1200ms 的 CountDownLatch await）
    public static let readyAckTimeout: TimeInterval = 1.2
    /// 等车机「安全响应」token（反编译：2800ms，超时文案「未收到车辆安全响应」）
    public static let secureResponseTimeout: TimeInterval = 2.8
    /// 等车机「蓝牙确认」（反编译：3000ms，超时文案「等待车辆蓝牙确认超时」）
    public static let vehicleConfirmTimeout: TimeInterval = 3.0
}

// MARK: - 控制通道握手帧（Luk0.a 反汇编逐指令复刻）
//
// 官方控制通道不是「连上就能发指令」，而是一段握手：
//   ① 发 prime 帧  `*BT,<pke>,10,001,7#`  → 车机回带 `7` 字段的 ready ack（≤1200ms）
//   ② 发参数写     `AT+SET_PARAM=5,<v>\n`  → 车机回 SET_PARAM_OK / SET_PARAM_FAIL
//   ③ 发氛围灯     `AT+SET_RGB=<v>\n`      → 车机回 RGBOK / RGBFAIL
//   ④ 车机下发「安全响应」token（≤2800ms）→ 之后再回带同一 token 的帧 = 蓝牙确认
//   ⑤ 读参数       `AT+READ_PARAM\n`       → 车机回 READ_PARAM
// 只有走完这些，`*UClear,<pke>#` 这类指令才是"通道已认"状态下发出的。

public enum ControlPrime {
    /// 组帧：StringBuilder("*BT,") + pke + ",10,001,7#"（反汇编原文）
    ///
    /// ⚠️ 本方法**不校验** pkeCode —— 它是纯拼接。空 pke 会拼出 `*BT,,10,001,7#`，
    ///    车机必然不应答。所以调用方**必须先过 `VehicleKey.isValid`**（见 VehicleControlService）。
    public static func frame(pkeCode: String) -> String {
        "*BT,\(pkeCode),10,001,7#"
    }
}

/// 车辆钥匙（pkeCode）校验 —— 单一口径，别在别处再写一遍判空。
///
/// 为什么值得单独一个类型（2026-10-01 实测）：
///   未登录 / 车辆列表没拉到 / 未选中车辆时 `activePKECode` 是 nil，
///   上游用 `?? ""` 兜了一下，于是握手帧变成 `*BT,,10,001,7#` 被**静默发出去**，
///   用户只看到「指令超时」，根本猜不到是缺钥匙。空 pke 是"车机不应答"的头号原因。
public enum VehicleKey {
    public static func isValid(_ pkeCode: String) -> Bool {
        !pkeCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// AT 参数通道。反汇编全库只有这三条（`AT+READ_PARAM` / `AT+SET_PARAM=5,` / `AT+SET_RGB=`），
/// 且**都以换行结尾**（不是 `#`）——这是和明文指令帧最大的区别。
public enum ATCommand {
    public static let readParam = "AT+READ_PARAM\n"
    public static func setParam5(_ value: String) -> String { "AT+SET_PARAM=5,\(value)\n" }
    public static func setRGB(_ value: String) -> String { "AT+SET_RGB=\(value)\n" }
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

    /// 组帧 = 前缀 + 逗号 + pke + `#`（Lmfa.a 的 9 个前缀都**自带尾部逗号**，见 `PlaintextCommand`）。
    /// ⚠️ 2026-10-01 反汇编补挖后的结论：帧本身没问题，
    ///   之前「控车不灵」更可能卡在**通道握手**（prime → ready ack → 参数写 → 安全响应）没走完。
    ///   真车日志到手后，若握手全绿而指令被拒，再回来动这个方法。
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
    /// 去帧尾 `#` 后按 `,` 分段（官方 Lmfa 也是这个预处理顺序）
    public static func fields(of text: String) -> [String] {
        text
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .components(separatedBy: ",")
    }

    /// 按反汇编语法判定一帧：split(",") → 首段 "0#" 失败；尾段 ",OK#" 成功；"FAIL" 失败；*BR 主动上报
    public static func verdict(of text: String) -> FrameVerdict {
        if text.hasPrefix("*BR") { return .unsolicited(text) }
        let parts = fields(of: text)
        if let first = parts.first, first == "0" || first == "0#" {
            return .fail(reason: "车机返回失败帧（首段 0#）")
        }
        if text.contains("FAIL") {
            return .fail(reason: "车机返回 FAIL")
        }
        if text.hasSuffix(",OK#") || text.hasSuffix("OK#") {
            return .ok(fields: parts)
        }
        return .unrelated
    }

    // MARK: 控制通道握手观测（反汇编推断，待真车日志确认）

    /// 车机对 prime 帧的 ready ack。
    /// 依据：Lxk0.n 里用 `Ljfa;->a("7", fields)` 判定、命中就 countDown 那个 1200ms 的 latch
    /// —— prime 帧最后一个字段正是 `7`，车机把「我准备好了」回带在同一个字段里。
    public static func isReadyAck(of text: String) -> Bool {
        fields(of: text).contains("7")
    }

    /// 车机下发的「安全响应」token。
    /// 依据：Lxk0.n 取**第 5 段**（index 4）→ trim → 大写 → 去 `#`，非空即视为 token
    /// 并存入 AtomicReference（随后车机再回一帧带同一 token 的 = 蓝牙确认）。
    /// ⚠️ 反汇编推断：token 的用途（是否要回签）尚未解出，这里只做**观测记录**，不据此放行。
    public static func secureToken(of text: String) -> String? {
        let f = fields(of: text)
        guard f.count > 4 else { return nil }
        let trimmed = f[4]
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

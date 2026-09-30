import Foundation
import UIKit

// MARK: - 启动轨迹 / 崩溃留痕
//
// 自签包装到真机上没有 Xcode 控制台，闪退原因完全不可见。
// 本工具做两件事：
//   1. phase 标记：把「启动走到第几步」同步写进沙盒文件；
//      进程被杀后文件还留着，下次启动一读就知道死在哪一段。
//   2. 未捕获异常处理：UIKit / KVO / 数组越界等 NSException 的原因与栈顶落盘。
//      （Swift 的 fatalError、强制解包 nil 不走这里，但配合 phase 足够定位。）
//
// 结果展示在「我的」工段的「启动诊断」卡里。

// 全局常量：C 函数指针闭包不能捕获上下文，只能引用全局
private let zrCrashURL: URL = {
    let fm = FileManager.default
    let dir = (try? fm.url(for: .documentDirectory, in: .userDomainMask,
                           appropriateFor: nil, create: true))
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return dir.appendingPathComponent("last-crash.txt")
}()

private let zrPhaseURL: URL = {
    let fm = FileManager.default
    let dir = (try? fm.url(for: .documentDirectory, in: .userDomainMask,
                           appropriateFor: nil, create: true))
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return dir.appendingPathComponent("launch.phase.txt")
}()

public enum LaunchTrace {

    /// 建议在 App init 里调用一次
    public static func install() {
        NSSetUncaughtExceptionHandler { ex in
            let text = """
            \(ex.name.rawValue)
            \(ex.reason ?? "（无 reason）")

            --- 栈顶 ---
            \(ex.callStackSymbols.prefix(15).joined(separator: "\n"))
            """
            try? text.data(using: .utf8)?.write(to: zrCrashURL, options: .atomic)
        }
    }

    /// 打点（同步落盘，进程下一刻死了也留得住）
    public static func mark(_ phase: String) {
        try? phase.data(using: .utf8)?.write(to: zrPhaseURL, options: .atomic)
    }

    public static var phase: String? {
        (try? String(contentsOf: zrPhaseURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static var crash: String? {
        (try? String(contentsOf: zrCrashURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func clearCrash() {
        try? FileManager.default.removeItem(at: zrCrashURL)
    }

    /// 上次是否正常跑起来了（phase == stable 视为跑通）
    public static var lastLaunchSurvived: Bool { phase == "stable" }
}

import Foundation
import UIKit

// MARK: - 启动轨迹 / 崩溃留痕
//
// 自签包装到真机上没有 Xcode 控制台，闪退原因完全不可见。本工具负责三件事：
//   1. phase 打点：把「启动走到第几步」同步写进沙盒 Documents。
//      配合 Info.plist 的 UIFileSharingEnabled，用户**不用进 App**，
//      直接在系统「文件」App → 我的 iPhone → 升仕车机 里就能读到；
//   2. 未捕获异常：NSSetUncaughtExceptionHandler 把 NSException 的原因与栈顶落盘；
//   3. 启动尝试计数：连续两次没跑到 stable，下次直接进裸诊断界面。
//      —— SwiftData 的 fatalError、Swift 强制解包 nil 都不走 NSException，
//      光靠 1/2 抓不到，所以必须有「起不来也要能进 App 看诊断」这条兜底路径。

// 全局常量：C 函数指针闭包不能捕获上下文，只能引用全局
private let zrDocsURL: URL = {
    let fm = FileManager.default
    return (try? fm.url(for: .documentDirectory, in: .userDomainMask,
                        appropriateFor: nil, create: true))
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
}()

private let zrCrashURL = zrDocsURL.appendingPathComponent("last-crash.txt")
private let zrPhaseURL = zrDocsURL.appendingPathComponent("launch.phase.txt")
private let zrAttemptKey = "zr.launch.attempts"

public enum LaunchTrace {

    /// 建议在 App init 里最先调用
    public static func install() {
        NSSetUncaughtExceptionHandler { ex in
            let text = """
            \(ex.name.rawValue)
            \(ex.reason ?? "（无 reason）")

            --- 栈顶 ---
            \(ex.callStackSymbols.prefix(20).joined(separator: "\n"))
            """
            try? text.data(using: .utf8)?.write(to: zrCrashURL, options: .atomic)
        }
    }

    /// 打点（同步落盘，进程下一刻死了也留得住）
    public static func mark(_ phase: String) {
        try? phase.data(using: .utf8)?.write(to: zrPhaseURL, options: .atomic)
    }

    // MARK: - 启动尝试计数（连续失败兜底）

    /// 启动时调用：本次算一次尝试
    public static func beginLaunchAttempt() {
        let n = UserDefaults.standard.integer(forKey: zrAttemptKey)
        UserDefaults.standard.set(n + 1, forKey: zrAttemptKey)
    }

    /// 连续两次没跑起来 → 下次直接进裸诊断界面
    public static var shouldEnterDiagnosticMode: Bool {
        UserDefaults.standard.integer(forKey: zrAttemptKey) >= 2
    }

    /// 启动挂到 stable → 清零计数
    public static func launchSucceeded() {
        UserDefaults.standard.set(0, forKey: zrAttemptKey)
    }

    /// 用户点「重试正常启动」时用
    public static func reset() {
        UserDefaults.standard.set(0, forKey: zrAttemptKey)
        try? FileManager.default.removeItem(at: zrCrashURL)
        try? FileManager.default.removeItem(at: zrPhaseURL)
    }

    public static var attempts: Int { UserDefaults.standard.integer(forKey: zrAttemptKey) }

    // MARK: - 读取

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

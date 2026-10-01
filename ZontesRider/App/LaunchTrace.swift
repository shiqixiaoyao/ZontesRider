import Foundation
import UIKit
import Darwin

// MARK: - 启动轨迹 / 崩溃留痕
//
// 自签包（以及 LiveContainer 这类"容器内跑 App"的环境）拿不到 Xcode 控制台，
// 闪退原因完全不可见。本模块负责四件事：
//   1. phase 打点：把「启动走到第几步」**同步**写进沙盒（落盘 + 追加步骤流水），
//      进程下一刻死掉也留得住；
//   2. 未捕获 NSException：NSSetUncaughtExceptionHandler 落盘原因与栈顶；
//   3. **信号级崩溃**：Swift 的致命错误（`fatalError` / 强解包 nil / 区间 trap /
//      `try!`）走的是 SIGTRAP / SIGILL，**根本不经过 NSException** ——
//      2026-09-30 那次 `1..<0` 就是因为这个，所以必须单独装信号处理器
//      （只用异步信号安全的 write()，写完恢复默认处理并重新抛出，不吞崩溃）；
//   4. 多路径落盘：LiveContainer 下 guest 的 Documents 藏在 LC 自己的容器里，
//      用户可能在「文件」App 里找不到 —— 所以同时写 Documents / Application Support /
//      tmp 三处，并在诊断页把「到底写在哪、内容是什么」**直接显示在屏幕上**，
//      让用户截一张图就能定位（不需要会找文件）。
//
// ⚠️ 全局量说明：信号处理器里不能碰 Swift 运行时（不能分配内存、不能格式化字符串），
//    因此 phase 文本存在**预分配好的 C 缓冲**里，处理器只做 write()。

// 全局常量：C 函数指针闭包不能捕获上下文，只能引用全局
private let zrDocsURL: URL = {
    let fm = FileManager.default
    return (try? fm.url(for: .documentDirectory, in: .userDomainMask,
                        appropriateFor: nil, create: true))
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
}()

private let zrSupportURL: URL = {
    let fm = FileManager.default
    return (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                        appropriateFor: nil, create: true))
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
}()

private let zrTmpURL = URL(fileURLWithPath: NSTemporaryDirectory())

/// 三处候选落盘目录（顺序即优先级）。LiveContainer / 越狱环境下总能命中至少一个。
private let zrPhaseURLs: [URL] = [
    zrDocsURL.appendingPathComponent("launch.phase.txt"),
    zrSupportURL.appendingPathComponent("launch.phase.txt"),
    zrTmpURL.appendingPathComponent("launch.phase.txt"),
]

private let zrCrashURL = zrDocsURL.appendingPathComponent("last-crash.txt")
private let zrStepsURL = zrDocsURL.appendingPathComponent("launch.steps.txt")
private let zrAttemptKey = "zr.launch.attempts"

// MARK: - 信号处理器用的静态资源（异步信号安全）

/// phase 文本（处理器只读它）
nonisolated(unsafe) private let zrPhaseBuf: UnsafeMutablePointer<CChar> = {
    let p = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
    p.initialize(repeating: 0, count: 256)
    return p
}()

/// 崩溃留档的常开 fd（在 install() 里打开，处理器只 write()）
nonisolated(unsafe) private var zrCrashFD: Int32 = -1

/// 每种信号的提示串，install() 时预填好
nonisolated(unsafe) private var zrSigNote: UnsafeMutablePointer<CChar>? = nil

private func zrSetPhaseBuf(_ text: String) {
    text.withCString { src in
        strncpy(zrPhaseBuf, src, 255)
        zrPhaseBuf[255] = 0
    }
}

/// 信号处理器：只做 write()，然后恢复默认处理并重新抛出（不吞崩溃、不改变系统行为）
private func zrSignalHandler(_ sig: Int32) {
    if zrCrashFD >= 0 {
        let n = strlen(zrPhaseBuf)
        if n > 0 { _ = write(zrCrashFD, zrPhaseBuf, n) }
        if let note = zrSigNote {
            _ = write(zrCrashFD, note, strlen(note))
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

public enum LaunchTrace {

    // MARK: - 安装

    /// 建议在 App init 里最先调用
    public static func install() {
        // ① 把 phase 缓冲初始化一次（确保处理器运行时内存已就绪）
        zrSetPhaseBuf("phase=（尚未打点）\n")

        // ② 开好崩溃留档 fd（常开；O_APPEND 保证多次崩溃不会互相覆盖）
        if zrCrashFD < 0 {
            let path = zrCrashURL.path
            zrCrashFD = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        }

        // ③ 信号提示串（预分配，处理器里不做任何分配/格式化）
        if zrSigNote == nil {
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
            p.initialize(repeating: 0, count: 64)
            "[SIGNAL 崩溃] 上面的 phase 即最后一步\n".withCString { src in
                strncpy(p, src, 63)
                p[63] = 0
            }
            zrSigNote = p
        }

        // ④ 未捕获 NSException
        NSSetUncaughtExceptionHandler { ex in
            let text = """
            [NSException] \(ex.name.rawValue)
            \(ex.reason ?? "（无 reason）")

            --- 栈顶 ---
            \(ex.callStackSymbols.prefix(20).joined(separator: "\n"))
            """
            try? text.data(using: .utf8)?.write(to: zrCrashURL, options: .atomic)
        }

        // ⑤ 信号级崩溃：Swift 的 fatalError / 强解包 / 区间 trap / try! 都在这里现形
        for s in [SIGTRAP, SIGILL, SIGABRT, SIGSEGV, SIGBUS, SIGFPE] {
            signal(s, zrSignalHandler)
        }

        // ⑥ 本次启动的步骤流水从头记
        try? FileManager.default.removeItem(at: zrStepsURL)
    }

    // MARK: - 打点

    /// 打点（同步落盘，进程下一刻死了也留得住）
    ///
    /// ⚠️ phase 文件里**只写阶段名本身**（不要加别的内容）：
    ///    CI 靠 `phase == probe.done` 判定页面级探针是否跑完，
    ///    `RootView` 安全模式也靠它判断上次是否跑通 —— 一加料就全废。
    ///    要给人看的解释性文字放「步骤流水」和诊断页。
    public static func mark(_ phase: String) {
        zrSetPhaseBuf("phase=\(phase)\n[若本行之后没有新的打点，就是死在这一步之后的代码里]\n")
        let data = Data(phase.utf8)
        for url in zrPhaseURLs {
            try? data.write(to: url, options: .atomic)
        }
        let line = "\(stamp.string(from: Date())) \(phase)\n"
        if let h = try? FileHandle(forWritingTo: zrStepsURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: zrStepsURL)
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

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
        for url in zrPhaseURLs { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: zrStepsURL)
    }

    public static var attempts: Int { UserDefaults.standard.integer(forKey: zrAttemptKey) }

    // MARK: - 读取

    public static var phase: String? {
        for url in zrPhaseURLs {
            if let t = try? String(contentsOf: url, encoding: .utf8),
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    public static var crash: String? {
        (try? String(contentsOf: zrCrashURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 本次启动的步骤流水（诊断页直接显示，用户截图即可）
    public static func steps(limit: Int = 1200) -> String {
        guard let t = try? String(contentsOf: zrStepsURL, encoding: .utf8) else { return "（无）" }
        return t.count > limit ? String(t.suffix(limit)) : t
    }

    /// 每个候选落盘位置是否存在、内容是什么 —— 用户只截图就能告诉我写在哪了
    public static var locations: [(path: String, content: String?)] {
        zrPhaseURLs.map { url in
            (url.path, try? String(contentsOf: url, encoding: .utf8))
        }
    }

    public static func clearCrash() {
        try? FileManager.default.removeItem(at: zrCrashURL)
        if zrCrashFD >= 0 {
            close(zrCrashFD)
            let path = zrCrashURL.path
            zrCrashFD = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        }
    }

    /// 上次是否正常跑起来了（phase == stable 视为跑通）
    public static var lastLaunchSurvived: Bool { phase == "stable" }
}

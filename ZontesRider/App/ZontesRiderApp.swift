import SwiftUI
import SwiftData

// MARK: - App 入口
//
// 启动路径的纪律（自签包拿不到控制台日志，任何一步崩了就是「点开即闪退」且无从查起）：
//   1. 第一件事装异常钩子 + 落盘打点，后面每一步都留痕；
//   2. **绝不允许**启动期出现会 fatalError 的调用——SwiftData 的默认容器构造失败时会直接
//      把进程带走（磁盘上残留的旧 store 与当前 Schema 不兼容就会命中），所以这里自己
//      做三级降级：正常打开 → 删库重建 → 内存库。宁可油耗记录本次不落盘，也要能起来；
//   3. 蓝牙不在启动路径上（BLESession 已惰性化，只有用户点「连接车机」才建 CBCentralManager）；
//   4. 万一还是起不来，连续两次失败后自动改走 LaunchDiagnosticView，
//      保证用户**一定**能进到 App 里看到「死在哪一步」。

@main
struct ZontesRiderApp: App {
    @State private var auth: AuthStore
    private let container: ModelContainer
    private let diagnosticMode: Bool

    init() {
        // ① 先把崩溃钩子装上，后面任何 NSException 都会落盘
        LaunchTrace.install()
        LaunchTrace.mark("app.init")

        // ② 连续两次启动都没跑到 stable → 本次直接进裸诊断界面
        diagnosticMode = LaunchTrace.shouldEnterDiagnosticMode
        LaunchTrace.beginLaunchAttempt()

        // ③ 登录态仓库（只读 Keychain，失败也只是没有会话，不会崩）
        _auth = State(initialValue: AuthStore())
        LaunchTrace.mark("auth.ready")

        // ④ 数据容器：诊断模式不碰磁盘库，正常模式走三级降级
        container = diagnosticMode ? Self.makeMemoryContainer() : Self.makeContainer()
        LaunchTrace.mark(diagnosticMode ? "app.diagnostic" : "app.ready")
    }

    var body: some Scene {
        WindowGroup {
            if diagnosticMode {
                LaunchDiagnosticView()
            } else {
                RootView()
                    .environment(auth)
                    .modelContainer(container)
                    .preferredColorScheme(.dark)
                    .task {
                        LaunchTrace.mark("root.mounted")
                        // 挂满 2 秒没有再死，就认为这次启动是健康的，清零失败计数
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        LaunchTrace.launchSucceeded()
                        LaunchTrace.mark("stable")
                    }
            }
        }
    }

    // MARK: - SwiftData 容器的三级降级

    /// 磁盘库 → 删掉损坏库重建 → 内存库。全失败才真的没辙（理论上到不了）。
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([FuelEntry.self])

        // 第 1 级：正常打开磁盘库
        if let c = try? ModelContainer(for: schema) {
            LaunchTrace.mark("container.disk-ok")
            return c
        }
        LaunchTrace.mark("container.disk-failed")

        // 第 2 级：磁盘上残留的 store 可能损坏 / 与当前 Schema 不兼容 → 删掉重建
        wipeStoreFiles()
        if let c = try? ModelContainer(for: schema) {
            LaunchTrace.mark("container.rebuild-ok")
            return c
        }
        LaunchTrace.mark("container.rebuild-failed")

        // 第 3 级：内存库兜底（油耗记录本次不持久化，但 App 一定能起来）
        LaunchTrace.mark("container.memory-ok")
        return makeMemoryContainer()
    }

    private static func makeMemoryContainer() -> ModelContainer {
        let schema = Schema([FuelEntry.self])
        let memory = ModelConfiguration(isStoredInMemoryOnly: true)
        if let c = try? ModelContainer(for: schema, configurations: memory) {
            return c
        }
        // 兜底：内存库几乎不可能失败，而返回不了容器就必然崩，别无选择
        return try! ModelContainer(for: schema, configurations: memory)
    }

    /// 删掉 SwiftData 的默认磁盘库（含 -shm / -wal 附属文件）
    private static func wipeStoreFiles() {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory,
                                in: .userDomainMask).first else { return }
        for name in ["default.store", "default.store-shm", "default.store-wal",
                     ".default.support", "default.store-journal"] {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

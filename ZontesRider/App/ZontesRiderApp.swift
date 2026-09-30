import SwiftUI
import SwiftData

@main
struct ZontesRiderApp: App {
    @State private var auth = AuthStore()

    init() {
        LaunchTrace.install()
        LaunchTrace.mark("app.init")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .modelContainer(for: FuelEntry.self)
                .preferredColorScheme(.dark)
                .task {
                    LaunchTrace.mark("root.task")
                    // 跑满 6 秒没有再死，就认为这次启动是健康的
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    LaunchTrace.mark("stable")
                }
        }
    }
}

import SwiftUI
import SwiftData

@main
struct ZontesRiderApp: App {
    @State private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .modelContainer(for: FuelEntry.self)
                .preferredColorScheme(.dark)
        }
    }
}

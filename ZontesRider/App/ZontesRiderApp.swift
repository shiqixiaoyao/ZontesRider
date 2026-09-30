import SwiftUI
import SwiftData

@main
struct ZontesRiderApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(for: FuelEntry.self)
                .preferredColorScheme(.dark)
        }
    }
}

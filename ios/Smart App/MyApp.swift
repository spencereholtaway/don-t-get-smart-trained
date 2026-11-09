import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Trains, crossings and live data only update while the app is on screen.
            if phase == .active { model.start() } else if phase == .background { model.stop() }
        }
    }
}

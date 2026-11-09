import SwiftUI

/// Three modes, as tabs: Rider (the default), Driver and Horse. The last tab used is remembered.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView(selection: Binding { model.mode } set: { model.setMode($0) }) {
            ForEach(Mode.allCases) { mode in
                Tab(mode.title, systemImage: mode.systemImage, value: mode) {
                    MapScreen(mode: mode)
                }
            }
        }
        // The system tab bar, so it moves to the side on iPhone Duo; the selected tab in the brand green.
        .tint(.accent)
        .task { model.locate() }
    }
}

extension Mode {
    var title: LocalizedStringKey {
        switch self {
        case .rider: "Rider"
        case .driver: "Driver"
        case .horse: "Horse"
        }
    }

    var systemImage: String {
        switch self {
        case .rider: "tram.fill"
        case .driver: "car.fill"
        case .horse: "figure.equestrian.sports"
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}

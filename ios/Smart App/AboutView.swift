import SwiftUI

/// Where the data comes from.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Link(destination: URL(string: "https://www.buymeacoffee.com/holtaway")!) {
                        Label("Like this? Buy me a coffee!", systemImage: "cup.and.saucer.fill")
                    }
                }
                Section {
                    Link("Timetable and live data from 511.org",
                         destination: URL(string: "https://511.org/open-data/transit")!)
                    Link("Level crossings from OpenStreetMap",
                         destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    Link("Predicted traffic based on a report from sonomamarintrain.org",
                         destination: URL(string: "https://www.sonomamarintrain.org/sites/default/files/Board/COC%20Documents/Item%20%237-%20San%20Rafael%20Gate%20Down%20Time%20Presentation_04.06.2022_0.pdf")!)
                } header: {
                    Text("Data")
                } footer: {
                    Text("All times are estimates. Always follow the crossing signals.")
                }
            }
            .navigationTitle("About")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AboutView()
}

import SwiftData
import SwiftUI

struct AppShellView: View {
    var body: some View {
        ConnectionLibraryView()
    }
}

#Preview {
    AppShellView()
        .frame(width: 980, height: 680)
        .environmentObject(ShortcutSettingsStore())
        .modelContainer(for: ConnectionProfile.self, inMemory: true)
}

import SwiftUI

/// Owns the app's long-lived, dependency-injected state and hands it to
/// the view tree via the environment. `FirmwareLibrary` and
/// `EmulatorCore` are constructed exactly once here.
struct RootView: View {
    @State private var firmwareLibrary = FirmwareLibrary()
    @State private var emulatorCore = EmulatorCore()

    @AppStorage(AppStorageKeys.appearance) private var appearanceRawValue = AppearanceOption.system.rawValue

    private var preferredColorScheme: ColorScheme? {
        AppearanceOption(rawValue: appearanceRawValue)?.colorScheme
    }

    var body: some View {
        MainScreen()
            .environment(firmwareLibrary)
            .environment(emulatorCore)
            .preferredColorScheme(preferredColorScheme)
    }
}

#Preview {
    RootView()
}

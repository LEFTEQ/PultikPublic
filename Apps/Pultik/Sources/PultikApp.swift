import SwiftUI

@main
struct PultikApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Everything visible lives in AppDelegate: the status item and panel
        // (see its note on why MenuBarExtra can't be used), and the Settings
        // window (see SettingsWindow — the `Settings` scene is unsummonable
        // from an LSUIElement app, which is why it isn't one).
        //
        // `App` still requires a Scene, and an empty Settings scene is the
        // cheapest one that adds no window and no menu item. LSUIElement has
        // no menu bar, so ⌘, never fires and this stays inert.
        Settings { EmptyView() }
    }
}

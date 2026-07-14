import AppKit

@main
@MainActor
struct BasiliskApp {
    static func main() {
        // Read user's language pref BEFORE AppKit starts loading anything —
        // AppleLanguages is resolved once per process, so a later toggle
        // wouldn't re-localize existing menus / cached SwiftUI text.
        LanguagePreference.applyEarly()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

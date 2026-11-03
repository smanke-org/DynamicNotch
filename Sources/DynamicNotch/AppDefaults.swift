import Foundation

/// Where DynamicNotch keeps its settings: UserDefaults.standard, except in a Debug agent CLI test
/// copy (`APP_STORE=<folder>`), which gets a domain of its own. Test copies share the installed
/// app's bundle ID, and with it its preferences, so without this a setting changed on a test copy
/// (or the sync timestamp it stores) would land in the real app's settings.
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if AgentSocket.isTestRun, let suite = UserDefaults(suiteName: testSuiteName) { return suite }
        #endif
        return .standard
    }()

    /// The test copy's own domain; delete it with `defaults delete com.smanke.DynamicNotch.agenttest`.
    static let testSuiteName = "com.smanke.DynamicNotch.agenttest"
}

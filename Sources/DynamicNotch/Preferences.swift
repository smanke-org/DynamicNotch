import Foundation
import Observation
import SwiftUI

/// How the notch opens and closes.
enum NotchAnimation: String, CaseIterable, Identifiable {
    /// The black shape stretches out of the notch with a little bounce, the album art slides
    /// into place, and the rows sharpen in one after another.
    case grow
    /// The open notch fades in at full size over the closed one.
    case fade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grow: "Grow"
        case .fade: "Fade"
        }
    }

    var detail: String {
        switch self {
        case .grow: "The notch stretches open with a little bounce, the album art slides into place and each row comes into focus in turn."
        case .fade: "The open notch fades in at full size, without moving."
        }
    }

    /// The animation for a change to `expanded`: opening gets the bounce, closing tucks
    /// straight back in.
    func animation(opening: Bool) -> Animation {
        switch self {
        case .grow: opening ? .spring(response: 0.42, dampingFraction: 0.68) : .spring(response: 0.34, dampingFraction: 0.92)
        case .fade: .easeInOut(duration: opening ? 0.22 : 0.18)
        }
    }
}

/// Which displays get a notch.
enum NotchDisplays: String, CaseIterable, Identifiable {
    /// The display with the notch, else the built-in one, else the main one.
    case builtIn
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtIn: "The built-in display"
        case .all: "Every display"
        }
    }
}

/// Every setting, persisted to UserDefaults as it changes.
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()

    var openAnimation: NotchAnimation = .grow { didSet { save(openAnimation.rawValue, "openAnimation") } }
    var notchDisplays: NotchDisplays = .builtIn {
        didSet {
            save(notchDisplays.rawValue, "notchDisplays")
            if notchDisplays != oldValue { NotificationCenter.default.post(name: Self.displaysDidChange, object: nil) }
        }
    }

    /// Posted when `notchDisplays` changes, here or from another Mac.
    static let displaysDidChange = Notification.Name("Preferences.displaysDidChange")

    /// Every key this class writes.
    static let keys = ["openAnimation", "notchDisplays"]

    @ObservationIgnored private var loading = false

    private init() { load() }

    /// Every setting's current value, in the form UserDefaults stores it, defaults included.
    /// iCloud gets the whole set, so a Mac adopting it never mistakes a setting that is
    /// merely at its default for one that is missing.
    var snapshot: [String: Any] {
        ["openAnimation": openAnimation.rawValue, "notchDisplays": notchDisplays.rawValue]
    }

    /// Re-reads every setting after another Mac's settings were written into UserDefaults.
    func reload() { load() }

    private func load() {
        loading = true
        defer { loading = false }
        openAnimation = UserDefaults.standard.string(forKey: "openAnimation").flatMap(NotchAnimation.init) ?? .grow
        notchDisplays = UserDefaults.standard.string(forKey: "notchDisplays").flatMap(NotchDisplays.init) ?? .builtIn
    }

    /// Writes only real changes, and reports them for iCloud sync. SwiftUI controls write
    /// their current value back when settings arrive from another Mac; counting those as
    /// edits would send the same settings back and forth between Macs forever.
    private func save(_ value: String, _ key: String) {
        guard !loading else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: key) == value { return }
        defaults.set(value, forKey: key)
        SettingsSync.shared.localDidChange()
    }
}

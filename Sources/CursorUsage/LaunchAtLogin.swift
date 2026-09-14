import Foundation
import ServiceManagement

/// Login-item registration via SMAppService (macOS 13+). This is the same thing
/// System Settings → General → Login Items & Extensions shows and toggles, so the
/// user can flip it from either place and both stay in sync.
///
/// Only works when running from a real .app bundle (`make install`); `swift run`
/// has no bundle identifier and register() would just throw.
enum LaunchAtLogin {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        guard isAvailable else { return "Launch at login needs the installed app (make install)." }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// First launch from /Applications: register automatically, once. If the user
    /// later turns it off in System Settings we respect that and never re-register.
    static func registerOnFirstRun() {
        let key = "didAutoRegisterLoginItem"
        guard isAvailable, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status == .notRegistered { set(true) }
    }
}

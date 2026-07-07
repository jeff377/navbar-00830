import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService` (macOS 13+). Works once the app runs from a stable
/// location (e.g. /Applications) as a proper bundle; from a raw `swift run` the status is
/// typically `.notFound` and toggling is a no-op, which is fine for development.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("NAV830: login item toggle failed: \(error.localizedDescription)")
        }
    }
}

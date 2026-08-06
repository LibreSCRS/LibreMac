// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Bringing a menu-bar-only app forward, and putting it back. Both halves are
// subtler than they look and both were learned from windows disappearing, so
// they live in one place rather than being restated at each call site.

import AppKit

@MainActor
enum AppActivation {
    /// Promote and activate for a window or panel, returning the policy to put
    /// back. An accessory app is never the active application, so anything it
    /// opens lands BEHIND whatever was frontmost — a settings window opened
    /// from the menu bar appeared behind the terminal it was launched from.
    static func begin() -> NSApplication.ActivationPolicy {
        let previous = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        return previous
    }

    /// Restoring `.accessory` hides every ordinary window the app still has
    /// open, so it is restored ONLY when none is left: a user who opened the
    /// credentials window and then cancelled a file pick watched that window
    /// vanish with it.
    ///
    /// Deferred one run-loop turn because a window closing right now is still
    /// listed in `NSApp.windows`. Counting it as open would leave the app
    /// promoted, wearing a Dock icon it is not supposed to have.
    static func end(restoring previous: NSApplication.ActivationPolicy) {
        DispatchQueue.main.async {
            let hasOrdinaryWindow = NSApp.windows.contains {
                $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain
            }
            if !hasOrdinaryWindow {
                NSApp.setActivationPolicy(previous)
            }
        }
    }
}

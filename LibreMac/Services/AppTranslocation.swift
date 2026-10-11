// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0
//
// Gatekeeper runs a quarantined app opened from where it was downloaded (or
// straight from its disk image) from a randomized read-only mount. A
// LaunchAgent registered from there points at a path that is gone after the
// next restart. The system answer comes from SecTranslocateIsTranslocatedURL,
// which Security.framework exports but no public header declares, so it is
// looked up at run time; without it the path decides.

import Darwin
import Foundation

enum AppTranslocation {
    /// `nil` = the system could not answer.
    typealias Probe = (URL) -> Bool?

    static func isTranslocated(_ url: URL, probe: Probe = { systemProbe($0) }) -> Bool {
        if let answer = probe(url) { return answer }
        return url.standardizedFileURL.pathComponents.contains("AppTranslocation")
    }

    private typealias IsTranslocatedFn = @convention(c) (
        CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Bool

    static func systemProbe(_ url: URL) -> Bool? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateIsTranslocatedURL")
        else { return nil }
        let fn = unsafeBitCast(symbol, to: IsTranslocatedFn.self)
        var translocated = false
        guard fn(url as CFURL, &translocated, nil) else { return nil }
        return translocated
    }
}

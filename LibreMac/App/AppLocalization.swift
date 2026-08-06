// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Foundation
import LibreMacShared
import Observation

/// The host's single localization entry point.
///
/// Seven private copies of this used to exist, one per view. The language
/// override is applied here and nowhere else: `LocalizedText.resolve` keeps
/// its `.main` default, so the token extension — which shares
/// `LibreMacShared` — is unaffected by anything the host's user chooses.
/// Main-actor isolated: this is view state, read while rendering and written
/// from a settings control, and never touched off the main actor. That is
/// what lets `shared` be a plain static under strict concurrency.
@MainActor
@Observable
final class AppLocalization {
    /// The one instance the app injects. Static contexts and the `App` value
    /// itself reach it directly; everything rendered inside a scene reads the
    /// same object out of the environment.
    static let shared = AppLocalization(defaults: .standard)

    @ObservationIgnored private let defaults: UserDefaults

    /// Stored separately so the public property can persist on write. The
    /// `@Observable` macro turns stored properties into computed ones, which
    /// rules out a `didSet` observer here; reading and writing through
    /// `locale` still tracks, because it goes through this.
    private var chosenLocale: String?

    /// Resolved once per language rather than per string: `loc` is called
    /// from view bodies, and looking a bundle up by path on every call puts
    /// filesystem work in the render path.
    @ObservationIgnored private var cachedBundle: Bundle?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.string(forKey: AppGroupConstants.DefaultsKeys.preferredLocale)
        self.chosenLocale = stored
        self.cachedBundle = Self.bundle(for: stored)
    }

    private static func bundle(for locale: String?) -> Bundle? {
        guard let locale, let path = Bundle.main.path(forResource: locale, ofType: "lproj")
        else { return nil }
        return Bundle(path: path)
    }

    /// The language the user picked, or nil to follow the system's preferred
    /// language order.
    var locale: String? {
        get { chosenLocale }
        set {
            chosenLocale = newValue
            cachedBundle = Self.bundle(for: newValue)
            if let newValue {
                defaults.set(newValue, forKey: AppGroupConstants.DefaultsKeys.preferredLocale)
            } else {
                defaults.removeObject(forKey: AppGroupConstants.DefaultsKeys.preferredLocale)
            }
        }
    }

    /// Resolves an already-built text — the shape the error-copy tables and
    /// the agent-facing view models produce — against the chosen language.
    func resolve(_ text: LocalizedText) -> String {
        // Reading `locale` is not redundant: it is what registers the
        // observation dependency that redraws a view when the language
        // changes. The cached bundle is deliberately untracked, so resolving
        // through it alone leaves every caller unaware that anything moved.
        guard locale != nil, let cachedBundle else { return text.resolve() }
        return text.resolve(bundle: cachedBundle)
    }

    /// Resolves against the chosen language's bundle, falling back to the
    /// key's English default. An override naming a language the bundle does
    /// not carry resolves as if no override were set.
    func loc(_ key: String, _ fallback: String,
             placeholders: [String: String] = [:]) -> String {
        resolve(LocalizedText(key: key, defaultText: fallback, placeholders: placeholders))
    }

}

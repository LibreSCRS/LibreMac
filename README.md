# LibreMac

macOS-native integration for [LibreSCRS](https://github.com/LibreSCRS) smart card stack.

LibreMac is a SwiftUI menu bar host plus a CryptoTokenKit token extension that
exposes Serbian eID, eMRTD, and other supported cards to Keychain, Safari,
Mail.app, and PAM login.

## Architecture

macOS uses the same single-owner model as Linux: exactly one process owns
LibreMiddleware, and everyone else is a thin client. That owner is a per-user
**agent** — the same cross-platform agent as LibreLinux, with a macOS backend:
a Unix-domain socket in an App-Group container, launchd, and a macOS prompter.

LibreMac itself is **LibreMiddleware-free**, like LibreKDE:

- The **menu bar host** is a native SwiftUI client of the agent.
- The **CryptoTokenKit extension** is a thin PKCS#11→Keychain bridge. It
  ATR-gates only and never drives the card; the agent does. It needs no
  Apple-gated entitlement — just `keychain-access-groups` and `app-sandbox`.

PIN consent uses the protected authentication path
(`CKF_PROTECTED_AUTHENTICATION_PATH`).

## Status

Work in progress. A de-risk spike passed on real hardware: the macOS agent
holds a warm PACE/SM session under active `ctkd` and signs. The macOS agent
backend is on the roadmap. The repo's current direct-LibreMiddleware bridge is
superseded by the model above.

## Building

Requires:
- macOS 15.0+ (Sequoia or later)
- Xcode 16+
- CMake 3.24+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Python 3.11+ (for LibreMiddleware codegen)

Quick start:

```bash
./Scripts/build-cmake-side.sh
./Scripts/generate-project.sh    # runs xcodegen
open LibreMac.xcodeproj
```

## License

LGPL-2.1-or-later. See [LICENSE](LICENSE).

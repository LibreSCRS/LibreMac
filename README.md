# LibreMac

macOS-native integration for [LibreSCRS](https://github.com/LibreSCRS) smart card stack.

LibreMac is a SwiftUI menu bar host plus a CryptoTokenKit token extension.
The host publishes a present card's signing identities (Serbian eID RSA
signing certificates) to the Keychain, where Safari, Mail.app, and other
Keychain clients can use them. Planned, not yet shipped: further card
families and PAM login. eMRTD documents carry no Keychain-usable PKI
identity and remain a reading feature of the host and agent.

## Architecture

macOS uses the same single-owner model as Linux: exactly one process owns
LibreMiddleware, and everyone else is a thin client. That owner is a per-user
**agent** — the same cross-platform agent as LibreLinux, with a macOS backend:
a Unix-domain socket in an App-Group container, launchd, and a macOS prompter.

LibreMac itself is **LibreMiddleware-free**, like LibreKDE:

- The **menu bar host** is a native SwiftUI client of the agent.
- The **CryptoTokenKit extension** is a thin PKCS#11→Keychain bridge; the
  host, not the extension, ATR-gates and builds the identities. The
  extension never drives the card — the agent does. It needs no
  Apple-gated entitlement — just `keychain-access-groups` and `app-sandbox`.

PIN consent uses the protected authentication path
(`CKF_PROTECTED_AUTHENTICATION_PATH`).

## Status

Work in progress. A de-risk spike passed on real hardware: the macOS agent
holds a warm PACE/SM session under active `ctkd` and signs. The host is now a
pure agent client — it links no card stack and speaks to the agent over the
App-Group socket. The agent itself is built and shipped separately.

## Building

The host is pure Swift with no C/C++ build step. Requires:
- macOS 15.0+ (Sequoia or later)
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

Quick start:

```bash
./Scripts/generate-project.sh    # runs xcodegen
open LibreMac.xcodeproj
```

## License

LGPL-2.1-or-later. See [LICENSE](LICENSE).

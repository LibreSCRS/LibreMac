# LibreMac

macOS-native integration for [LibreSCRS](https://github.com/LibreSCRS) smart card stack.

LibreMac provides a SwiftUI menu bar host application and (in v1.0) a CryptoTokenKit
extension that exposes Serbian eID, eMRTD, and other LibreMiddleware-supported cards
to Keychain, Safari, Mail.app, and PAM login.

## Status

- **P1 + P2 source code in place.** Menu-bar host app, PIN entry sheet, certificate enumeration, RSA-PKCS signing path against `rs-eid` cards via a direct C++ bridge to LibreMiddleware. The end-to-end signing path has NOT been exercised against a real card under CI; the P2 manual smoke test is deferred until a USB CCID reader and `rs-eid` card are available in a hardware-enabled session.
- P3 (CAN/PACE/eMRTD) — next; see [`docs/P3-PROGRESS.md`](docs/P3-PROGRESS.md).
- P4 (CTK appex, system-wide Safari/Mail.app integration) — gated on Apple `developer.smartcard-services` entitlement grant.

## Building

Requires:
- macOS 15.0+ (Sequoia or later)
- Xcode 16+
- CMake 3.24+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Python 3.11+ (for LibreMiddleware codegen)

Quick start:

```bash
./Scripts/build-cmake-side.sh    # builds the C++ bridge static archive
./Scripts/generate-project.sh    # runs xcodegen
open LibreMac.xcodeproj
```


## License

LGPL-2.1-or-later. See [LICENSE](LICENSE).

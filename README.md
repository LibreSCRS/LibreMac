# LibreMac

macOS-native integration for [LibreSCRS](https://github.com/LibreSCRS) smart card stack.

LibreMac provides a SwiftUI menu bar host application and (in v1.0) a CryptoTokenKit
extension that exposes Serbian eID, eMRTD, and other LibreMiddleware-supported cards
to Keychain, Safari, Mail.app, and PAM login.

## Release-track positioning

LibreMac is a **separate release track** from LibreMiddleware (LM) and
LibreCelik (LC). LibreMac v0.1 follows the LM 4.1 cycle, not the LM 4.0
tag — the gating items are universal-binary verification on real
hardware, the P2 manual smoke against a real `rs-eid` card, and the
P4 CTK appex (entitlement-gated).

### How LibreMac talks to LibreMiddleware

LibreMac has two independent integration paths into LM, picked per use
case:

1. **Menu bar host app** uses a **private C++/Swift `BridgeNative`** that
   wraps LM's public C++ API directly. The bridge lives in this repo
   (`BridgeNative/`); its `lm_*` C surface is internal to LibreMac and
   not part of any LM public contract. This is the right shape for a
   single-process app that wants rich, typed access to LM
   (PIN UX, structured certificate enumeration, lifecycle control).

2. **CTK appex (P4)** will use **PKCS#11** — LM's standardised C API,
   already shipped as `librescrs-pkcs11.so`. Apple's `ctkd` daemon
   loads the appex into its own process; the appex's Swift `TKToken`
   implementation calls the PKCS#11 entry points (`C_Initialize`,
   `C_Sign`, `C_GetSlotList`, …) directly — Swift can call C without
   a shim. No LM-proprietary C ABI is needed: PKCS#11 v3.0 is the
   industry-standard C surface, and LM exposes it.

Consequence: LM does not need to invent a public proprietary C ABI
just for LibreMac. The C++ surface covers the menu bar app via the
private bridge; PKCS#11 covers the appex via direct linking. Both
paths are stable.

## Status

- **P1 + P2 source code in place.** Menu-bar host app, PIN entry sheet, certificate enumeration, RSA-PKCS signing path against `rs-eid` cards via a direct C++ bridge to LibreMiddleware. The end-to-end signing path has NOT been exercised against a real card under CI; the P2 manual smoke test is deferred until a USB CCID reader and `rs-eid` card are available in a hardware-enabled session.
- P3 (CAN/PACE/eMRTD) — next; see [`docs/P3-PROGRESS.md`](docs/P3-PROGRESS.md).
- P4 (CTK appex, system-wide Safari/Mail.app integration) — gated on Apple `developer.smartcard-services` entitlement grant. The appex consumes LM's existing PKCS#11 module (`librescrs-pkcs11`); no new C ABI work is required on the LM side.

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

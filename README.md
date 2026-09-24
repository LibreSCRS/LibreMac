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
  host, not the extension, builds the identities — publishing only
  signing-capable certificates whose SHA-256(DER) matches the claimed id.
  The extension never drives the card — the agent does. It needs no
  Apple-gated entitlement — just `keychain-access-groups` and `app-sandbox`.

PIN consent uses the protected authentication path
(`CKF_PROTECTED_AUTHENTICATION_PATH`).

Without a Developer ID signature the agent and prompter cannot verify who
connects to them beyond same-user ownership of the socket; a process running
as your user can raise the credential window. Developer-ID builds verify the
peer's designated requirement. See [SECURITY.md](SECURITY.md) for the full
policy.

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

## Release checklist

CI does not assemble the bundle that ships the agent: that needs a LibreDarwin
build tree and a signing identity. It is assembled and checked locally:

```bash
xcodebuild -project LibreMac.xcodeproj -scheme LibreMac -configuration Release build
./Scripts/bundle-agent.sh <path-to>/LibreMac.app <LibreDarwin build dir> <LibreMiddleware lib dir>
./Scripts/verify-bundle.sh <path-to>/LibreMac.app
```

`bundle-agent.sh` stages the agent, the prompter and the LibreMiddleware
libraries into the app Xcode built, signs each of them with the hardened
runtime, and signs the host `.app` itself as its **last** step. Do not sign the
bundle again after it, and do not copy anything into it: the host's signature
seals the bundle, and a change after the seal is a bundle that no longer
verifies. The token extension keeps the signature Xcode gave it, because only
Xcode expands `$(AppIdentifierPrefix)` in its keychain entitlement.
`verify-bundle.sh` fails on a bundle that does not verify end to end.

## License

LGPL-2.1-or-later. See [LICENSE](LICENSE).

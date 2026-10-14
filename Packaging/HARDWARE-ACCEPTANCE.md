<!--
SPDX-License-Identifier: LGPL-2.1-or-later
SPDX-FileCopyrightText: 2026 hirashix0
-->
# CryptoTokenKit hardware acceptance gate (deferred)

The CryptoTokenKit token extension and its package tests are implemented
and green in CI on unsigned Debug builds. The checks below can only run
against a Developer-ID-signed build talking to `ctkd`, the per-user agent,
and a physical smart card — none of which CI has. They are **not** part of
the automated test suite; run them manually as a release-readiness gate
before shipping a signed build.

## Prerequisites

- A bundle signed by `Scripts/sign-bundle.sh` with the App Groups and
  (app-sandbox for the extension) entitlements the processes need
  at runtime (a Developer ID identity, once there is one). Unsigned Xcode
  builds (`CODE_SIGNING_ALLOWED: NO`, what CI uses) are not sufficient — `ctkd` will not register an
  unsigned/untrusted extension against Keychain.
- A physical smart card reader with a supported card inserted.
- A local `LibreDarwin` checkout, built, and a `LibreMiddleware` install
  prefix — needed by the automated pre-check below.
- The target card's real CAN and PIN, ready to export for the pre-check and
  to type into the prompter during Check 4. Do not hardcode either anywhere
  in scripts or logs.
- PIN safety: this gate consumes the real card PIN. Apply the same
  `g_pinFailed` + `loginWithAbort()` + `SKIP_IF_PIN_FAILED()` discipline used
  by the rest of the test suite — three failed PIN attempts permanently
  block the card, so abort the remaining checks after the first failure
  rather than retrying blind.

## Automated pre-check

Before working through the manual checks below, run LibreDarwin's own
hardware smoke test. It drives the same agent core end to end (Hello ->
GetState -> ReadCertificates -> Sign) against the live card over a real
socket, and it is the only thing in this project that actually reads
`LIBRESCRS_HW` / `LIBRESCRS_TEST_CAN` / `LIBRESCRS_TEST_PIN`. A pass here is
confidence in the lower layers before debugging the CTK/Keychain path by
hand; it is not a substitute for Checks 1-7, which exercise `ctkd` and the
extension that this test does not touch.

```bash
cd <path-to>/LibreDarwin
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH=<LibreMiddleware install prefix>
cmake --build build -j4

LIBRESCRS_HW=1 \
LIBRESCRS_PLUGIN_DIR=<LibreMiddleware install prefix>/lib/librescrs/plugins \
LIBRESCRS_TEST_CAN=<the card's real CAN> \
LIBRESCRS_TEST_PIN=<the card's real signing PIN> \
  ctest --test-dir build -R SignHwSmokeTest -V

unset LIBRESCRS_TEST_PIN LIBRESCRS_TEST_CAN
```

`agent/tests/SignHwSmokeTest.cpp` reads these four variables directly (the
plugin dir has a built-in fallback and can be left unset if the default
install path applies). Unset `LIBRESCRS_TEST_PIN` and `LIBRESCRS_TEST_CAN`
immediately after the run, as shown above, so the real PIN does not linger
in the shell's environment for the rest of the session. A wrong signing PIN
decrements the card's on-card retry counter, so the test aborts on the
first auth failure and does not retry blind — the same PIN-safety guard as
the rest of the suite.

## Checks

1. **End-to-end signature.** From a Keychain-consuming app (or a small
   `SecKeyCreateSignature` harness), request an RSA signature using
   `…DigestPKCS1v15Raw` over the token identity. Confirm the call path runs
   `ctkd` → `LibreMacToken.appex` → agent → prompter, that the prompter
   collects the PIN, and that the returned signature verifies against the
   certificate's public key. A card opened with a CAN whose RSA key the card
   hashes for itself cannot sign a DigestInfo: confirm none of its RSA keys
   appears in `security find-identity -v` (its EC keys, if any, still do), so
   no PIN prompt is ever raised for a signature it would refuse.

2. **Presence tracking.** Remove the card and confirm the identity
   disappears from `security find-identity -v`. Re-insert the card and
   confirm the identity is republished without restarting any process.

3. **Card pulled mid-operation.** Start a sign, then physically remove the
   card between the identity picker and the signature call. Confirm a clean
   failure: `TokenNotFound` if the pre-check catches the missing card,
   otherwise `CommunicationError`. Confirm — by agent/extension logs — that
   no PIN verify attempt reaches the card in this path (removing the card
   must not itself count as, or trigger, a PIN attempt).

4. **Per-operation consent follows the card.** The token's auth operation
   does nothing and the extension logs in only after the agent reports a
   lapsed session, so no login precedes a signature. Run every bullet with
   `LIBRESCRS_ENABLE_QES_KEYCHAIN=1`, so the qualified (`nonRepudiation`)
   identity is among the keys tested. On macOS each `TKTokenSession` owns its
   own agent connection, and the agent lease is keyed on that connection and
   the card, so a leaseholder is one session, not one machine.
   - Key the card marks for consent per operation (PKCS#15 `userConsent`;
     PIV 9C): sign twice in a row within one session; exactly one PIN prompt
     per signature.
   - Key the card does not mark: two signatures within one session (same
     client process and `LAContext`); one PIN prompt for the first, none for
     the second, if it follows within 45 s. After 45 s idle the agent closes
     the card session and one more PIN prompt is expected (the recovery path);
     past 10 min idle the lease lapses and a new `Login granted` and prompt
     follow. A second client process (or a new `LAContext`) gets its own
     session and lease, and is prompted once again; that is expected, not a
     defect.
   - In the agent log, count `pkcs11: Login granted` lines: exactly one per
     session, logged after the first signature's `userNotLoggedIn`, and none
     for later signatures in that session while the lease lasts (10 min idle).
   - Record which keys of each test card are marked (the agent's certificate
     list reports `alwaysAuthenticate`; the smoke test prints the inventory),
     and which of the two behaviours the qualified key shows.

5. **No decrypt.** Confirm the token identity is not offered for decrypt
   operations anywhere in the system UI or API surface — the token signs and,
   with an EC key the agent derives with, performs key exchange (check 7); it
   never decrypts.

6. **EC signature (new Serbian ID card, P-384).** The identity appears in
   `security find-identity -v`; a `SecKeyCreateSignature` with
   `.ecdsaSignatureDigestX962SHA384` over a 48-byte digest returns a DER
   signature that verifies against the certificate; a 20-byte digest with
   `.ecdsaSignatureDigestX962` (no hash named, so Security.framework passes it
   through to the token) is refused — `SecKeyCreateSignature` reports
   `errSecParam` or `TKError.badParameter` — and the agent log shows no
   `Pkcs11.SignRaw`. In
   the agent's certificate inventory (smoke test) the key reads `keyType=EC
   keyBits=384` and its ID is the card's own (16 bytes).

7. **Key exchange (EC key the agent derives with).** With a card whose plugin
   derives (the new Serbian ID card once its driver is pinned),
   `SecKeyCopyKeyExchangeResult` with `.ecdhKeyExchangeStandard` against a
   fresh P-384 key returns the same secret as the other side computes. When
   the agent asks for the PIN (the first operation of a session, or every
   operation with a key the card marks for consent per operation; a key
   agreement inside a session already logged in raises no prompt), the
   prompt's operation line reads "Operation: Key agreement with the card key". Until then the identity
   offers no key exchange (`canPerformKeyExchange` is false) — record which.

## Gating

The qualified (`nonRepudiation`) identity stays disabled behind the
`LIBRESCRS_ENABLE_QES_KEYCHAIN` environment variable (unset/off by default)
until all seven checks above pass on a Developer-ID-signed build (check 7
passes by recording which of its two outcomes the card shows), with check 4
run with that identity enabled. The qualified key prompts for a PIN on each
signature only if the card marks it for per-operation consent; otherwise it
signs on one PIN per session, and the recorded result of check 4 states which
applies to the card being released. Do not set
that variable for a release build before this gate has been run and its
results recorded.

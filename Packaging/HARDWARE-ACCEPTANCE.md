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

- A Developer ID application certificate + provisioning profile capable of
  signing the host app, the nested `LibreMacToken.appex`, and the agent with
  the App Groups and (for the extension) keychain-access-groups entitlements
  they need at runtime. Unsigned/ad-hoc builds (`CODE_SIGNING_ALLOWED=NO`,
  what CI uses) are not sufficient — `ctkd` will not register an
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
hand; it is not a substitute for Checks 1-5, which exercise `ctkd` and the
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
  ctest --test-dir build -R SignHwSmokeTest --output-on-failure

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
   certificate's public key.

2. **Presence tracking.** Remove the card and confirm the identity
   disappears from `security find-identity -v`. Re-insert the card and
   confirm the identity is republished without restarting any process.

3. **Card pulled mid-operation.** Start a sign, then physically remove the
   card between the identity picker and the signature call. Confirm a clean
   failure: `TokenNotFound` if the pre-check catches the missing card,
   otherwise `CommunicationError`. Confirm — by agent/extension logs — that
   no PIN verify attempt reaches the card in this path (removing the card
   must not itself count as, or trigger, a PIN attempt).

4. **Qualified-key sole control.** With the qualified (`nonRepudiation`)
   identity enabled, sign twice over one warm agent↔card channel after a
   single PIN entry. Confirm the card demands a fresh `VERIFY` for the
   second signature (no signature reuse of the first PIN verification) and
   that the extension re-prompts for the PIN on each sign, not just the
   first.

   **Reconciliation item:** today the *first* signature in a session prompts
   twice — once from `beginAuthFor`'s auth operation (`TokenAuthOperation.finish()`
   calling `engine.login(certId:)`) and once more from the sign path's own
   `requireFreshAuth: true` login. This is fail-safe (it asks for more
   consent, never less), but it may be redundant. Confirm on hardware
   whether the `beginAuthFor` login is in fact redundant with the sign
   path's login and, if so, make `beginAuthFor`'s auth operation a no-op so
   each signature prompts exactly once.

5. **No decrypt.** Confirm the token identity is not offered for decrypt
   operations anywhere in the system UI or API surface — the token is
   sign-only.

## Gating

The qualified (`nonRepudiation`) identity stays disabled behind the
`LIBRESCRS_ENABLE_QES_KEYCHAIN` environment variable (unset/off by default)
until all five checks above pass on a Developer-ID-signed build. Do not set
that variable for a release build before this gate has been run and its
results recorded.

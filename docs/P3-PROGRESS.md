# Post-P2 → P3 follow-ups

P2 exit reached at this commit. Items intentionally deferred to P3:

- **CAN entry dialog.** SwiftUI sheet for 6-digit CAN with optional saved-card lookup.
- **Saved CAN management.** Keychain `kSecAccessControlBiometryCurrentSet` storage; MRU sort; cap=5 retry.
- **PACE / eMRTD plugin integration.** Set `setCredentials(session, "can", value)` before `readCard()` for eMRTD-class cards.
- **Document-number disambiguation.** Read MRZ post-PACE; surface in confirm dialog.
- **CTK appex (P4).** Out of P3 scope; gated on `developer.smartcard-services` entitlement grant.

# Known limitations of P2

- No CAN-required cards work (eMRTD, contactless ID).
- Default key reference `0x0010` is rs-eid-specific; other plugins will need `discoverKeyReferences()` integration (small bridge addition).
- No saved-card UI; every signing flow re-prompts for PIN.
- No XPC service (P4 territory).
- The end-to-end signing path is not yet exercised against a real card under CI; the P2 manual smoke test (T10.2 in the foundation plan) is deferred per the no-hardware-from-this-session policy. The next foreground session should plug in a USB CCID reader, insert an `rs-eid` card, and confirm the full flow.

# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities privately using GitHub Security
Advisories:

  https://github.com/LibreSCRS/LibreMac/security/advisories/new

For non-GitHub correspondence, contact the project release signing
identity:

  librescrs@proton.me

We respond to security reports within five business days, follow up
with an initial assessment within ten days, and agree a disclosure
window with the reporter before anything is published.

Advisories we publish appear under this repository's Security tab;
consumers pinned to 4.x should watch it.

## Scope

In scope: anything reachable from a smart card, a network peer or a
parsed document before it has been authenticated — card and APDU
input, network input, document parsing; the IPC boundary between this
component and its callers, and the authorization checks guarding it;
handling of PINs, keys and other secrets; and the supply chain of the
artifact this repository ships.

Out of scope: this project's own tests and fuzz harnesses, denial of
service an attacker can already achieve as the user of their own
agent, and findings in vendored third-party code that belong to the
upstream project instead.

## Release verification

LibreMac has not yet cut a tagged release. There is no `KEYS` file and
no release workflow in this repository yet, so there is nothing here
to verify today: no signed git tag, and no Sigstore cosign signature
over a built app bundle or disk image. This section describes what
exists now; it will name the verification steps once a release under
this policy exists.

## Supported versions

| Version | Supported |
|---------|-----------|
| 5.x     | ✅ Active  |
| 4.x     | ✅ Active  |
| 3.x     | ❌ EOL     |

# LibreMac — Changelog

Notable changes to LibreMac, newest first. There is no tagged release yet, so
every entry below describes a change to what you get by building from source.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased] — 5.0.0

### Added

- The Settings screen fills in the country-signing row rather than only
  declaring it, so the configuration key the agent publishes is visible and
  editable where a user would look for it.

### Changed

- The wire vocabulary mirror gained a name for a dismissed prompt, matching the
  agent and both hosts, and every surface that renders one now tells the two
  apart: the token extension answers CryptoTokenKit `canceledByUser` instead of
  a device error, and the credentials and settings windows say you closed the
  prompt rather than that the reader failed.

- The vocabulary gate now measures the CONSUMERS of the wire mirror, not just
  that the mirror carries the contract's names. A token nothing renders, a
  `default:` arm that swallows one, and a cancel folded back into a
  communication failure each fail the build.

- The version this tree is heading for is recorded in `VERSION`, and the app now
  states that version everywhere it states one: the bundle information, the token
  extension, and the name the host gives the agent when it connects. All three said
  0.1.0 before, which is a version this project never had.

### Notes

- There is no release workflow, `KEYS` file or notarized artifact here yet.
  Publishing a signed and notarized macOS artifact needs an Apple Developer ID,
  which this project does not have; until it does, this component is built from
  source.

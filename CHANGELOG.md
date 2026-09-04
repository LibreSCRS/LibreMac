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
  agent and both hosts. A cancelled PIN prompt is now distinguishable from a
  failed one on every surface.

- The version this tree is heading for is recorded in `VERSION`, so a source
  drop with no `.git` stamps the version it is actually part of.

### Notes

- There is no release workflow, `KEYS` file or notarized artifact here yet.
  Publishing a signed and notarized macOS artifact needs an Apple Developer ID,
  which this project does not have; until it does, this component is built from
  source.

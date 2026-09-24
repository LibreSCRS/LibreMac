# LibreMac — Changelog

Notable changes to LibreMac, newest first. There is no tagged release yet, so
every entry below describes a change to what you get by building from source.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased] — 5.0.0

### Added

- The Trust settings now show the country-signing anchors the agent actually
  holds: how many there are, how many issuing countries they cover, when the
  list was signed and accepted, who published it and whether that publisher's
  identity was established. A host that has never watched an import can now say
  what passports are checked against instead of leaving it unknown. If any
  accepted list carried no signing time the window says so, because a later
  import cannot then be refused for rolling the anchors back. "Nothing
  installed" is shown only when the agent reports exactly that — never as a
  report of zero anchors, and never because a value could not be read, which
  says so in its own words instead. The display is read-only; nothing is
  installed from this window.

- The Settings screen fills in the country-signing row rather than only
  declaring it, so the configuration key the agent publishes is visible and
  editable where a user would look for it.

### Changed

- The vocabulary gate now covers the request forms of the sign options and the
  wider config key set, which the contract publishes as unions of the closed
  groups they extend. The sentinel that asks the agent to choose a level, format
  or packaging is no longer a spelling typed into the gate — it is read back off
  the contract — and a config key appended on the agent side now fails here
  instead of passing unnoticed.

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

- The bundle's marketing version is now derived from `VERSION` instead of being
  typed a second and third time: the project spec takes it from the environment
  at generation time, and both the app and the token extension reference it
  rather than repeating a number. A hand-typed copy could disagree with
  `VERSION`, and nothing read the number Xcode actually stamped.

- The build version (`CFBundleVersion`) is now derived from `VERSION` the same
  way, through the generated project's `CURRENT_PROJECT_VERSION` setting. It
  used to be a literal `1` on both the app and the token extension, so a
  rebuild after a version bump left this number unchanged; launchd/SMAppService
  key an update's identity off it, so an unchanged `CFBundleVersion` is why an
  already-registered agent was never recycled even though the marketing version
  on screen had moved. The version check that reads the built app now compares
  this number too, not only the marketing string.

- With no hand-typed version left to read, the check that compared the project
  spec and the two `Info.plist` files against `VERSION` is gone, replaced by one
  that reads the number back off the built app and its nested token extension.
  The old check could only see the sources, which now state a build setting
  rather than a version; the new one measures what ships.

- The sentence that counts your remaining attempts now takes the grammatical
  number Serbian asks for — one form for 1 and 21, another for 2, a third for 5
  and 11 — instead of a number pasted into one fixed sentence. The catalog
  generator learned to read the plural forms out of the `.ts` sources, so the
  two signing sentences that count files and confirmations, which until now
  rendered their English source to a Serbian reader, are translated as well.

### Notes

- There is no release workflow, `KEYS` file or notarized artifact here yet.
  Publishing a signed and notarized macOS artifact needs an Apple Developer ID,
  which this project does not have; until it does, this component is built from
  source.

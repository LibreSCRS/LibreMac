#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
# SPDX-FileCopyrightText: 2026 hirashix0
#
# Consumer gate for the `sync-error` wire-vocabulary mirror.
#
# `WireVocabularyConformanceTests.expectTokenMirror` proves the Swift enum
# carries the same TOKEN SET the contract publishes. That is presence, not
# use: an appended token can sit in the enum while every place that turns it
# into an answer keeps folding it into the generic one. That is precisely what
# happened to `Cancelled` — the name landed in `AgentTypes.swift`, the
# vocabulary gate went green, and no consumer changed.
#
# So this gate reads the CONSUMERS:
#   1. the registry below names every non-test source mentioning `SyncError`;
#      a new one fails until it is registered with a role;
#   2. every `switch` whose subject this check can resolve to `SyncError` —
#      written as an identifier, a member chain, a call, or `self` inside a
#      `SyncError` body — sits at one of that file's registry anchors; a
#      second one, or one in a file whose role declares none, fails until it
#      is registered;
#   3. every anchored `switch` covers all cases and carries no catch-all arm
#      (`default:`, `@unknown default:` or `case _:`), so an appended token
#      cannot be swallowed without a build failure;
#   4. the distinctness pairs hold — the two names share neither a case arm
#      nor an answer.
#
# Pure python: no Xcode, no Swift toolchain. `--self-test` proves the gate can
# still fail, against a throwaway copy of the tree (the working tree is never
# written to).
#
# Threat model. This reads source TEXT with regular expressions, so it guards
# against the honest regression: someone writing this codebase's ordinary
# shapes appends a wire name, adds a consumer, or reaches for a `default:`
# arm, and forgets what that implies elsewhere. It is not a Swift parser and
# does not resist someone concealing intent. Doors it knowingly leaves open,
# named rather than left to be found again: a case name built by string or
# token trickery rather than written as `.name`; a `where` clause or an
# associated-value pattern (`case .a(let x)`) narrowing an arm it counts as
# whole; a consumer given a non-.swift extension or parked outside
# SOURCE_ROOTS; two arms whose bodies differ in text but compute the same
# answer; a `switch` whose subject this file gives no type for, since rule 2
# resolves a subject only through a `: SyncError` annotation in the same file,
# a same-file function declared to return it, or a `SyncError` body around a
# `switch self` — so a subscript (`switch a[i] {`), a closure result, or a
# value whose type only another file names stays invisible; and, most simply,
# deleting this gate or its CI step. Those are what code review is for. What
# it will not do is pass QUIETLY on a shape it cannot read: a missing anchor,
# a missing `switch`, or a mirror case with no explicit raw value is reported
# by name rather than skipped.
import re
import shutil
import sys
import tempfile
from pathlib import Path

DECLARATION = "LibreMacAgentClient/Sources/LibreMacAgentClient/AgentTypes.swift"

SOURCE_ROOTS = ["LibreMac", "LibreMacAgentClient/Sources", "LibreMacShared/Sources"]

# path -> (role, anchor)
#   "declaration" — the mirror itself
#   "decoder"     — wire token to enum; documented degrade, no switch
#   "folder"      — produces the enum from client-side errors, no switch on it
#   "switch"      — turns the enum into an answer; anchor = signature substring
#
# The anchor is `None`, one signature substring, or a tuple of them — one per
# `switch` over `SyncError` the file is allowed to carry. Every such switch
# the file holds must be named here; an unnamed one fails (rule 2 above),
# because only the anchored switches are read for coverage and `default:`.
REGISTRY = {
    DECLARATION: ("declaration", None),
    "LibreMacAgentClient/Sources/LibreMacAgentClient/Messages.swift": ("decoder", None),
    "LibreMacAgentClient/Sources/LibreMacAgentClient/TokenOpEngine.swift": (
        "switch", "func map(_ info: ErrInfo) -> TKErrorMapped"),
    "LibreMac/Services/ErrorCopy.swift": (
        "switch", "func localizedText(for error: SyncError) -> LocalizedText"),
    "LibreMac/ViewModels/PreferencesModel.swift": (
        "switch", "func copy(for name: SyncError) -> (String, String)"),
    "LibreMac/ViewModels/CredentialsViewModel.swift": ("folder", None),
}

# The invariant this pair carries: a person who dismissed a prompt must never
# be told the card reader broke. Add a pair here when a decision makes two
# names' answers load-bearing; the gate then holds every consumer to it.
DISTINCT_PAIRS = [("cancelled", "communicationError")]


def enum_cases(root):
    """(case names, problems) for the mirror enum.

    A `case` with no `= "Token"` is legal Swift — the compiler then gives it an
    implicit rawValue equal to the case name — but the contract publishes
    PascalCase tokens, so such a case would mirror the wrong string. It is
    counted like any other and reported, rather than dropped from the count and
    leaving every coverage line below measured against a short denominator.
    """
    text = (root / DECLARATION).read_text(encoding="utf-8")
    m = re.search(r"public enum SyncError[^\{]*\{(.*?)\n\}", text, re.S)
    if not m:
        sys.exit("FATAL: cannot find the SyncError declaration")
    names, problems = [], []
    for line in m.group(1).splitlines():
        s = line.strip()
        if not s.startswith("case "):
            continue
        for part in s[len("case "):].split(","):
            part = part.strip()
            nm = re.match(r"([A-Za-z][A-Za-z0-9_]*)", part)
            if not nm:
                continue
            names.append(nm.group(1))
            if "=" not in part:
                problems.append(
                    f"{DECLARATION}: `case {nm.group(1)}` carries no explicit raw value — the "
                    "contract publishes PascalCase tokens, so the implicit rawValue would "
                    "mirror the case name instead")
    if not names:
        sys.exit("FATAL: the SyncError declaration lists no cases")
    return names, problems


def mentioning_files(root):
    out = set()
    for src in SOURCE_ROOTS:
        for p in sorted((root / src).rglob("*.swift")):
            if "SyncError" in p.read_text(encoding="utf-8"):
                out.add(str(p.relative_to(root)))
    return out


def read_lines(root, path):
    return (root / path).read_text(encoding="utf-8").splitlines()


def anchor_list(anchor):
    if anchor is None:
        return ()
    return (anchor,) if isinstance(anchor, str) else tuple(anchor)


SWITCH_HEAD = re.compile(r"^\s*switch\s+(\S.*?)\s*\{\s*$")

SYNC_ERROR_BODY = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|final)\s+)*"
    r"(?:enum|extension)\s+SyncError\b")


def _bare(line):
    """The line with comments and string literals removed, for brace counting."""
    return re.sub(r"//.*$", "", re.sub(r'"(?:\\.|[^"\\])*"', '""', line))


def sync_error_bodies(lines):
    """0-based [start, end] spans of `enum`/`extension SyncError { … }` bodies.

    Inside one of these, `switch self {` is a switch over the vocabulary. The
    braces are counted on a copy with strings and comments stripped, so a brace
    inside a literal cannot close the span early.
    """
    spans = []
    for i, line in enumerate(lines):
        if not SYNC_ERROR_BODY.match(line):
            continue
        depth, opened = 0, False
        for j in range(i, len(lines)):
            bare = _bare(lines[j])
            depth += bare.count("{") - bare.count("}")
            opened = opened or "{" in bare
            if opened and depth <= 0:
                spans.append((i, j))
                break
        else:
            spans.append((i, len(lines) - 1))
    return spans


def switch_subject(expr):
    """The identifier a switch subject ends in, or None if it ends in neither.

    `self` is returned as itself; `a.b.c` and `f(x)` and `try a.f(x)` all
    resolve to the last identifier written, which is the name the resolver
    below looks up. A subscript or an operator expression resolves to nothing
    and is reported by the threat model as a door, not silently accepted.
    """
    e = re.sub(r"\(.*\)\s*$", "", expr.strip()).strip()
    m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", e)
    return m.group(1) if m else None


def sync_error_switches(lines):
    """0-based line numbers of every `switch` whose subject is a SyncError.

    A subject resolves when the file annotates it `: SyncError` (parameter,
    property or local), names a function the same file declares as returning
    `SyncError` (as a call subject, or through a `let` bound from one), or is
    `self` inside an `enum`/`extension SyncError` body. The subject may be
    written as a bare identifier, a member chain or a call — the codebase
    writes all three; the threat model above names what is still left open.
    """
    text = "\n".join(lines)
    subjects = set(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*SyncError\b", text))
    producers = re.findall(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^\n]*?->\s*SyncError\b", text)
    subjects.update(producers)
    for producer in producers:
        subjects.update(re.findall(
            r"\blet\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:[A-Za-z_][A-Za-z0-9_]*\.)*"
            + re.escape(producer) + r"\s*\(", text))
    bodies = sync_error_bodies(lines)
    out = []
    for i, line in enumerate(lines):
        m = SWITCH_HEAD.match(line)
        if not m:
            continue
        name = switch_subject(m.group(1))
        if name is None:
            continue
        if name == "self":
            if any(start <= i <= end for start, end in bodies):
                out.append(i)
        elif name in subjects:
            out.append(i)
    return out


def switch_span(lines, path, anchor):
    """(switch line, closing-brace line) for the switch at `anchor` — 0-based."""
    start = next((i for i, l in enumerate(lines) if anchor in l), None)
    if start is None:
        sys.exit(f"FATAL: {path}: no function matching {anchor!r} — "
                 "the signature moved; update REGISTRY rather than deleting the entry")
    sw = next((i for i in range(start, len(lines))
               if re.match(r"\s*switch .*\{\s*$", lines[i])), None)
    if sw is None:
        sys.exit(f"FATAL: {path}: no switch after {anchor!r}")
    indent = len(lines[sw]) - len(lines[sw].lstrip())
    end = next((i for i in range(sw + 1, len(lines))
                if lines[i].strip() == "}"
                and (len(lines[i]) - len(lines[i].lstrip())) == indent), len(lines))
    return sw, end


def switch_arms(lines, path, anchor):
    """[(is_default, pattern_names, body_text, header_lineno)] — 0-based."""
    sw, end = switch_span(lines, path, anchor)

    arms, pattern, body, closed, head_at = [], None, [], False, None

    # `@unknown default:` and the bare wildcard `case _:` are catch-alls like
    # any other: read as part of the preceding arm either would both hide the
    # catch-all and pollute that arm's body, which is what the answer
    # comparison below compares.
    def is_catch_all(s):
        return (s.startswith("default")
                or re.match(r"@unknown\s+default\b", s) is not None
                or re.match(r"case\s+_\s*(?::|$)", s) is not None)

    def is_arm_head(s):
        return s.startswith("case ") or is_catch_all(s)

    def flush():
        if pattern is None:
            return
        head = pattern.split(":", 1)[0]
        arms.append((is_catch_all(head.strip()),
                     set(re.findall(r"\.([a-z][A-Za-z0-9_]*)", head)),
                     "\n".join(x for x in body if x).strip(), head_at))

    for n in range(sw + 1, end):
        s = lines[n].strip()
        if not s or s.startswith("//"):
            continue
        if is_arm_head(s) and (pattern is None or closed):
            flush()
            pattern, body, closed, head_at = s, [], ":" in s, n
            if closed and s.split(":", 1)[1].strip():
                body.append(s.split(":", 1)[1].strip())
            continue
        if pattern is None:
            continue
        if not closed:
            pattern += " " + s
            if ":" in s:
                closed = True
                if s.split(":", 1)[1].strip():
                    body.append(s.split(":", 1)[1].strip())
        else:
            body.append(s)
    flush()
    return arms


def check(root, quiet=False):
    cases, failures = enum_cases(root)
    say = (lambda *a: None) if quiet else print
    say(f"SyncError declares {len(cases)} cases")

    found, registered = mentioning_files(root), set(REGISTRY)
    for p in sorted(found - registered):
        failures.append(f"{p}: mentions SyncError but is not in REGISTRY — register it with a "
                        "role, or the next appended token dies here unseen")
    for p in sorted(registered - found):
        failures.append(f"{p}: registered but no longer mentions SyncError — drop the entry")

    for path, (role, anchor) in sorted(REGISTRY.items()):
        anchors = anchor_list(anchor)
        lines = read_lines(root, path)
        anchored = {switch_span(lines, path, a)[0] for a in anchors}
        for n in sync_error_switches(lines):
            # `switch_arms` walks the arms of the switch at each anchor and
            # nothing else, so a second switch over the same enum — in this
            # file or in one whose role declares no anchor at all — would
            # keep its `default:` arm and its answers unread.
            if n not in anchored:
                failures.append(f"{path}:{n + 1}: a switch over SyncError that no registry anchor "
                                "names — only the anchored switches are read for coverage and "
                                "`default:`, so register this one with its own anchor")
        if not anchors:
            say(f"  {role:12s} {path}")
            continue
        for anchor_text in anchors:
            arms = switch_arms(lines, path, anchor_text)
            covered = set().union(*[names for _, names, _, _ in arms]) & set(cases)
            missing = sorted(set(cases) - covered)
            has_default = any(d for d, _, _, _ in arms)
            say(f"  switch       {path}  arms={len(arms)} covered={len(covered)}/{len(cases)} "
                f"default={'yes' if has_default else 'no'}")
            if has_default:
                failures.append(f"{path}: the switch over SyncError carries a `default:` arm — "
                                "an appended token is swallowed with no build failure")
            if missing:
                failures.append(f"{path}: the switch over SyncError does not handle {missing}")
            for a, b in DISTINCT_PAIRS:
                arm_a = next(((n, body) for _, n, body, _ in arms if a in n), None)
                arm_b = next(((n, body) for _, n, body, _ in arms if b in n), None)
                if arm_a is None or arm_b is None:
                    continue
                if a in arm_b[0] and b in arm_b[0]:
                    failures.append(f"{path}: `.{a}` shares a case arm with `.{b}` — "
                                    "a cancel would reach the user as a broken exchange")
                elif arm_a[1] == arm_b[1]:
                    failures.append(f"{path}: `.{a}` returns the same answer as `.{b}` "
                                    f"({arm_a[1]!r}) — the arms differ, the answer does not")

    if failures:
        say("\nFAIL")
        for f in failures:
            say(f"  - {f}")
        return 1, failures
    say("\nOK: every sync-error consumer is registered, exhaustive and distinct")
    return 0, []


# --- self-test ---------------------------------------------------------------
# Each entry perturbs a throwaway copy and names the message that must appear.
# A perturbation that changes nothing is itself a failure: a self-test that
# silently no-ops would report the gate healthy on a gate that cannot fail.

def _perturb_append_case(root):
    p = root / DECLARATION
    t = p.read_text(encoding="utf-8")
    old = '    case cancelled = "Cancelled"\n'
    if old not in t:
        return None
    p.write_text(t.replace(old, old + '    case selfTestProbe = "SelfTestProbe"\n', 1),
                 encoding="utf-8")
    return "does not handle ['selfTestProbe']"


def _perturb_unregistered_consumer(root):
    p = root / "LibreMac/Services/SelfTestConsumer.swift"
    p.write_text("import LibreMacAgentClient\n"
                 "func selfTestConsumer(_ e: SyncError) -> String { String(describing: e) }\n",
                 encoding="utf-8")
    return "is not in REGISTRY"


def _perturb_share_the_arm(root):
    p = root / "LibreMac/Services/ErrorCopy.swift"
    t = p.read_text(encoding="utf-8")
    old = "case .cancelled:"
    if old not in t:
        return None
    p.write_text(t.replace(old, "case .cancelled, .communicationError:", 1), encoding="utf-8")
    return "shares a case arm"


def _perturb_default_arm(root):
    path = "LibreMacAgentClient/Sources/LibreMacAgentClient/TokenOpEngine.swift"
    p = root / path
    lines = p.read_text(encoding="utf-8").splitlines()
    arms = switch_arms(lines, path, REGISTRY[path][1])
    if not arms:
        return None
    n = arms[-1][3]
    lines[n] = " " * (len(lines[n]) - len(lines[n].lstrip())) + "default:"
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return "carries a `default:` arm"


def _perturb_unknown_default(root):
    path = "LibreMacAgentClient/Sources/LibreMacAgentClient/TokenOpEngine.swift"
    p = root / path
    lines = p.read_text(encoding="utf-8").splitlines()
    sw, end = switch_span(lines, path, REGISTRY[path][1])
    lines.insert(end, " " * (len(lines[sw]) - len(lines[sw].lstrip()))
                 + "@unknown default: return .communicationError")
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return "carries a `default:` arm"


def _perturb_second_switch(root):
    """The shape the gate could not see before: a SECOND switch over the enum
    inside a file the registry already watches. Only the anchored one is read,
    so this one carried a `default:` arm and the communication answer for a
    cancel with the gate green."""
    p = root / "LibreMac/Services/ErrorCopy.swift"
    t = p.read_text(encoding="utf-8")
    anchor = "    public static func localizedText(for error: SyncError) -> LocalizedText {"
    if anchor not in t:
        return None
    extra = ("    static func selfTestLabel(for probe: SyncError) -> String {\n"
             "        switch probe {\n"
             "        case .cancelled: return \"broken\"\n"
             "        default: return \"broken\"\n"
             "        }\n"
             "    }\n\n")
    p.write_text(t.replace(anchor, extra + anchor, 1), encoding="utf-8")
    return "a switch over SyncError that no registry anchor names"


def _perturb_wildcard_arm(root):
    """`case _:` is Swift's other spelling of `default:`. A gate that reads
    only the word `default` prints `default=no` over a switch that has one."""
    path = "LibreMacAgentClient/Sources/LibreMacAgentClient/TokenOpEngine.swift"
    p = root / path
    lines = p.read_text(encoding="utf-8").splitlines()
    sw, end = switch_span(lines, path, REGISTRY[path][1])
    lines.insert(end, " " * (len(lines[sw]) - len(lines[sw].lstrip()))
                 + "case _: return .communicationError")
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return "carries a `default:` arm"


def _perturb_member_subject(root):
    """A second switch whose subject is written as a member chain rather than
    a bare identifier — the shape 14 of this tree's switches already use."""
    p = root / "LibreMac/ViewModels/CredentialsViewModel.swift"
    t = p.read_text(encoding="utf-8")
    anchor = "    private static func syncError(from error: Error) -> SyncError {"
    if anchor not in t:
        return None
    extra = ("    private var selfTestProbe: SyncError { entryError ?? .communicationError }\n"
             "    private func selfTestLabel() -> String {\n"
             "        switch self.selfTestProbe {\n"
             "        case .cancelled: return \"broken\"\n"
             "        default: return \"broken\"\n"
             "        }\n"
             "    }\n\n")
    p.write_text(t.replace(anchor, extra + anchor, 1), encoding="utf-8")
    return "a switch over SyncError that no registry anchor names"


def _perturb_call_subject(root):
    """A second switch written directly on the producing call — the shape
    `TokenOpEngine.map` itself carried before it was made exhaustive."""
    p = root / "LibreMac/ViewModels/CredentialsViewModel.swift"
    t = p.read_text(encoding="utf-8")
    anchor = "    private static func syncError(from error: Error) -> SyncError {"
    if anchor not in t:
        return None
    extra = ("    private static func selfTestLabel(_ error: Error) -> String {\n"
             "        switch Self.syncError(from: error) {\n"
             "        case .cancelled: return \"broken\"\n"
             "        default: return \"broken\"\n"
             "        }\n"
             "    }\n\n")
    p.write_text(t.replace(anchor, extra + anchor, 1), encoding="utf-8")
    return "a switch over SyncError that no registry anchor names"


def _perturb_extension_self(root):
    """`extension SyncError { switch self { … default: } }` — a consumer with
    no subject to annotate at all, in the file the registry calls the
    declaration and therefore gives no anchor."""
    p = root / DECLARATION
    t = p.read_text(encoding="utf-8")
    extra = ("\nextension SyncError {\n"
             "    var selfTestLabel: String {\n"
             "        switch self {\n"
             "        case .cancelled: return \"broken\"\n"
             "        default: return \"broken\"\n"
             "        }\n"
             "    }\n}\n")
    p.write_text(t + extra, encoding="utf-8")
    return "a switch over SyncError that no registry anchor names"


def _perturb_implicit_raw_value(root):
    """A case appended with no `= "Token"`: legal Swift, and the enum then
    mirrors the camelCase case name instead of the contract's token."""
    p = root / DECLARATION
    t = p.read_text(encoding="utf-8")
    old = '    case cancelled = "Cancelled"\n'
    if old not in t:
        return None
    p.write_text(t.replace(old, old + "    case selfTestProbe\n", 1), encoding="utf-8")
    return "carries no explicit raw value"


PERTURBATIONS = [
    ("an appended token no consumer handles", _perturb_append_case),
    ("a new consumer nobody registered", _perturb_unregistered_consumer),
    ("a cancel folded back into the communication arm", _perturb_share_the_arm),
    ("a `default:` arm re-introduced", _perturb_default_arm),
    ("an `@unknown default:` arm standing in for one", _perturb_unknown_default),
    ("a second switch over the enum in a registered file", _perturb_second_switch),
    ("a `case _:` wildcard standing in for a `default:`", _perturb_wildcard_arm),
    ("a second switch whose subject is a member chain", _perturb_member_subject),
    ("a second switch written on the producing call", _perturb_call_subject),
    ("a `switch self` inside an `extension SyncError`", _perturb_extension_self),
    ("a mirror case appended with no explicit raw value", _perturb_implicit_raw_value),
]


def self_test(root):
    # The first case is the control: the shipped tree must be green, or no
    # perturbation below means anything. Every other case is a perturbation
    # that must come back red, so the red-proved count is their number.
    cases = 1 + len(PERTURBATIONS)
    red = len(PERTURBATIONS)
    rc, _ = check(root, quiet=True)
    if rc != 0:
        print("SELF-TEST FAIL: the tree is already red; fix it before trusting the self-test")
        print(f"selftest: {cases} cases, {red} red-proved")
        return 1
    ok = True
    for name, perturb in PERTURBATIONS:
        with tempfile.TemporaryDirectory(prefix="sync-error-selftest-") as tmp:
            copy = Path(tmp) / "tree"
            for src in SOURCE_ROOTS + [str(Path(DECLARATION).parent)]:
                shutil.copytree(root / src, copy / src, dirs_exist_ok=True)
            expected = perturb(copy)
            if expected is None:
                print(f"  FAIL  {name}: the perturbation changed nothing")
                ok = False
                continue
            prc, failures = check(copy, quiet=True)
            hit = prc == 1 and any(expected in f for f in failures)
            print(f"  {'ok  ' if hit else 'FAIL'}  {name}"
                  + ("" if hit else f"\n        expected a failure containing {expected!r}, "
                                    f"got rc={prc} {failures}"))
            ok = ok and hit
    print("SELF-TEST PASS" if ok else "SELF-TEST FAIL")
    print(f"selftest: {cases} cases, {red} red-proved")
    return 0 if ok else 1


def main(argv):
    args = [a for a in argv[1:] if a != "--self-test"]
    root = Path(args[0]).resolve() if args else Path(__file__).resolve().parent.parent
    if "--self-test" in argv[1:]:
        return self_test(root)
    return check(root)[0]


if __name__ == "__main__":
    sys.exit(main(sys.argv))

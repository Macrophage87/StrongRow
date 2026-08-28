#!/usr/bin/env python3
"""Fail-closed check on the machine-checkable claims in docs/agents/FACTS.md.

WHY THIS EXISTS. docs/agents/FACTS.md is the ONE copy of the volatile facts the
agent loop shares, created so that a fact cannot drift into seven independent
paraphrases. But a single copy that nothing re-derives is only a slower kind of
drift: it goes stale silently instead of loudly, and this repository has
already shipped exactly that -- docs/AGENT_PROMPT.md asserts an environment
constraint that is false (#79) and a no-model-identifier rule that no job scans
for (#160). A rule stated in a document and enforced by no job is violated
silently for months.

So the five figures in that file which the tree can regenerate are regenerated
here, on every run of the required test-tooling job. scripts/check_ceiling_notes.py
is the precedent and the same shape: a machine-readable marker line beside the
prose, and arithmetic instead of assertion.

THE LINE FORMAT (in docs/agents/FACTS.md, anywhere, indented or not):

    <MARK> ci-container      sha256:<64 hex>
    <MARK> manifest-devices  <n>
    <MARK> pinned-tests      <n>
    <MARK> ceiling           <anchor> <used> <limit> <free>
    <MARK> devfield          <id> <name>          (one line per field)

where <MARK> is the word this module's MARK holds.

WHAT IS DERIVED, and from where:

  * ci-container      the sha256 on the `image: &ciq_image` anchor line in
                      .github/workflows/ci.yml -- the workflow's single copy,
                      aliased by every other container job;
  * manifest-devices  a real XML parse of manifest.xml, counting <iq:product>;
  * pinned-tests      the non-comment, non-blank line count of
                      scripts/expected_tests.txt;
  * ceiling           a CEILING note carrying that anchor must exist in the
                      tree with those three numbers. The scanner is IMPORTED
                      from scripts/check_ceiling_notes.py, not re-implemented:
                      a second note parser is a second thing to get wrong, and
                      this repository's own named failure is "a test that
                      re-implements logic instead of calling it pins nothing";
  * devfield          every createField call in source/StrongRowView.mc, read
                      TWICE and required to agree. The comment-stripped read
                      (scripts/list_tests.py's lexer, the repository's one
                      Monkey C lexer) yields the authoritative ID SET but
                      blanks string literals, so it cannot give names; the raw
                      read gives id->name but would also see a createField
                      written inside a comment. Requiring the two id sets to be
                      identical is what makes the raw read safe.

WHAT THIS CANNOT CHECK, stated so nobody reads more into a green run.

  * It compiles nothing, runs nothing and decodes nothing. It cannot tell you
    that the container digest still pulls, that 253 was ever the true globals
    count, that a Session accepts twenty-six fields, or what any decoder
    renders.
  * The ceiling check cannot tell you an anchor is the NEWEST one. Twelve
    anchors are in the tree; a stale-but-coherent note passes here exactly as
    it passes check_ceiling_notes.py.
  * Every prose claim in FACTS.md -- the environment contract, the command
    block, the incident narratives, the file:line citations, the permission
    proposal -- is invisible to this check. FACTS.md says so itself, in its
    own words, in the section that carries these lines.
  * It reads only docs/agents/FACTS.md. A copy of any of these figures made
    somewhere else is not seen. (The CEILING line is the exception, and only
    because check_ceiling_notes.py scans the whole tree for that marker.)

FAIL-CLOSED. A missing FACTS.md, a missing key, an unrecognised key, or a
derivation that cannot run are all failures. Deleting the marker lines must not
silently disable this check, which is why every key is REQUIRED rather than
merely validated when present.

Usage:
  check_agent_facts.py [--root DIR]

Exit 0 = every marker line agrees with the tree, 1 = at least one does not.
"""

import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# The repository's ONE Monkey C lexer, reused rather than copied.
from list_tests import strip_comments                     # noqa: E402
# The CEILING note scanner, imported for the same reason.
from check_ceiling_notes import scan as scan_ceiling      # noqa: E402

# Assembled so this file's own format examples and error strings are not
# themselves scanned as data, the way CEILING_WORD is in check_ceiling_notes.
MARK = "AGENT" + "FACT"

FACTS_REL = os.path.join("docs", "agents", "FACTS.md")

LINE_RE = re.compile(r"^\s*" + MARK + r"\s+(?P<key>[a-z-]+)\s+(?P<rest>.*?)\s*$")

IQ_NS = "http://www.garmin.com/xml/connectiq"

# The workflow's single digest copy: the anchor definition, not an alias.
ANCHOR_RE = re.compile(
    r"image:\s*&ciq_image\s+\S+@(?P<digest>sha256:[0-9a-f]{64})")

# name, id -- from the RAW source, so the literal survives the read.
CREATE_RAW_RE = re.compile(
    r'createField\(\s*"(?P<name>[^"]*)"\s*,\s*(?P<id>\d+)\s*,')
# id only -- from the comment-stripped source, where literals are blanked.
CREATE_STRIPPED_RE = re.compile(
    r'createField\(\s*"[^"]*"\s*,\s*(?P<id>\d+)\s*,')

REQUIRED_SINGLE = ("ci-container", "manifest-devices", "pinned-tests", "ceiling")


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def derive_container(root, problems):
    path = os.path.join(root, ".github", "workflows", "ci.yml")
    if not os.path.isfile(path):
        problems.append("%s is missing; the container digest cannot be derived."
                        % path)
        return None
    found = ANCHOR_RE.findall(read_text(path))
    if len(found) != 1:
        problems.append(
            "%s carries %d `image: &ciq_image <ref>@sha256:...` anchor "
            "definition(s); exactly one is expected. The digest is the pin, so "
            "a second definition or none at all is itself the defect."
            % (path, len(found)))
        return None
    return found[0]


def derive_devices(root, problems):
    path = os.path.join(root, "manifest.xml")
    if not os.path.isfile(path):
        problems.append("%s is missing; the device count cannot be derived."
                        % path)
        return None
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        problems.append("%s does not parse as XML: %s" % (path, exc))
        return None
    return len(tree.getroot().findall(".//{%s}product" % IQ_NS))


def derive_pinned_tests(root, problems):
    path = os.path.join(root, "scripts", "expected_tests.txt")
    if not os.path.isfile(path):
        problems.append("%s is missing; the pinned test count cannot be derived."
                        % path)
        return None
    n = 0
    for line in read_text(path).splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            n += 1
    return n


def derive_devfields(root, problems):
    """{id: name} for every createField call, read twice and required to agree."""
    path = os.path.join(root, "source", "StrongRowView.mc")
    if not os.path.isfile(path):
        problems.append("%s is missing; the developer-field map cannot be "
                        "derived." % path)
        return None
    text = read_text(path)
    raw = {}
    dupes = []
    for m in CREATE_RAW_RE.finditer(text):
        fid = int(m.group("id"))
        if fid in raw:
            dupes.append(fid)
        raw[fid] = m.group("name")
    if dupes:
        problems.append(
            "%s declares developer field id(s) %s more than once. An id is "
            "unique per field_description; a collision silently re-labels a "
            "field." % (path, ", ".join(str(d) for d in sorted(set(dupes)))))
        return None

    stripped_ids = set()
    for m in CREATE_STRIPPED_RE.finditer(strip_comments(text)):
        stripped_ids.add(int(m.group("id")))

    if set(raw) != stripped_ids:
        only_raw = sorted(set(raw) - stripped_ids)
        only_stripped = sorted(stripped_ids - set(raw))
        problems.append(
            "%s: the raw and comment-stripped reads of createField disagree "
            "(raw-only ids %s, stripped-only ids %s). The raw read is the one "
            "that can see a call written inside a comment, so a disagreement "
            "is refused rather than resolved."
            % (path, only_raw or "none", only_stripped or "none"))
        return None
    return raw


def derive_ceiling(root, anchor, problems):
    """(used, limit, free) for the note carrying `anchor`, or None."""
    hits = []
    for path, lineno, m, _raw in scan_ceiling(root):
        if m.group("anchor") == anchor:
            hits.append((path, lineno,
                         int(m.group("used")), int(m.group("limit")),
                         int(m.group("free"))))
    if not hits:
        problems.append(
            "no CEI" "LING note in the tree carries the anchor %r. FACTS.md "
            "quotes that anchor as the current headroom; if the note was "
            "renamed or removed, the quotation is stale." % anchor)
        return None
    # check_ceiling_notes.py already fails if two copies of one anchor differ,
    # so taking the first is safe here and is not a second opinion on that.
    _p, _l, used, limit, free = hits[0]
    return used, limit, free


def parse_facts(path, problems):
    """{key: [rest, ...]} for every marker line in FACTS.md."""
    facts = {}
    for line in read_text(path).splitlines():
        m = LINE_RE.match(line)
        if m:
            facts.setdefault(m.group("key"), []).append(m.group("rest"))
    known = set(REQUIRED_SINGLE) | {"devfield"}
    for key in sorted(set(facts) - known):
        problems.append(
            "%s carries an unrecognised %s key %r. A typo in a key would "
            "otherwise mean the line is never checked, which is the failure "
            "mode this file exists to prevent." % (path, MARK, key))
    for key in REQUIRED_SINGLE:
        got = facts.get(key, [])
        if len(got) != 1:
            problems.append(
                "%s carries %d %s %s line(s); exactly one is required. A "
                "deleted line must fail here, not silently disable the check."
                % (path, len(got), MARK, key))
    if not facts.get("devfield"):
        problems.append(
            "%s carries no %s devfield line. The developer-field id map is "
            "not pinned anywhere else -- check_step_fields.py pins the count "
            "and the uniqueness, not the id-to-name binding."
            % (path, MARK))
    return facts


def check_single(facts, key, derived, problems, label):
    if key not in facts or len(facts[key]) != 1 or derived is None:
        return                        # already reported
    stated = facts[key][0].strip()
    want = str(derived)
    if stated != want:
        problems.append("%s %s says %r; the tree gives %r (%s)."
                        % (MARK, key, stated, want, label))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    root = args.root

    problems = []
    facts_path = os.path.join(root, FACTS_REL)
    if not os.path.isfile(facts_path):
        print("FAIL: %s is missing. The agent loop's canonical facts file is "
              "required; without it every definition's pointers dangle."
              % facts_path)
        return 1

    facts = parse_facts(facts_path, problems)

    check_single(facts, "ci-container", derive_container(root, problems),
                 problems, "the &ciq_image anchor in .github/workflows/ci.yml")
    check_single(facts, "manifest-devices", derive_devices(root, problems),
                 problems, "<iq:product> entries in manifest.xml")
    check_single(facts, "pinned-tests", derive_pinned_tests(root, problems),
                 problems, "names in scripts/expected_tests.txt")

    # ceiling: <anchor> <used> <limit> <free>
    if len(facts.get("ceiling", [])) == 1:
        parts = facts["ceiling"][0].split()
        if len(parts) != 4 or not all(p.isdigit() for p in parts[1:]):
            problems.append(
                "%s ceiling should read `<anchor> <used> <limit> <free>`; got "
                "%r." % (MARK, facts["ceiling"][0]))
        else:
            anchor = parts[0]
            stated = tuple(int(p) for p in parts[1:])
            got = derive_ceiling(root, anchor, problems)
            if got is not None and got != stated:
                problems.append(
                    "%s ceiling %s says %d used of %d, %d free; the note in "
                    "the tree says %d used of %d, %d free."
                    % ((MARK, anchor) + stated + got))

    derived_fields = derive_devfields(root, problems)
    if derived_fields is not None and facts.get("devfield"):
        stated_fields = {}
        malformed = []
        for rest in facts["devfield"]:
            parts = rest.split()
            if len(parts) != 2 or not parts[0].isdigit():
                malformed.append(rest)
                continue
            stated_fields[int(parts[0])] = parts[1]
        for bad in malformed:
            problems.append("%s devfield should read `<id> <name>`; got %r."
                            % (MARK, bad))
        missing = sorted(set(derived_fields) - set(stated_fields))
        extra = sorted(set(stated_fields) - set(derived_fields))
        if missing:
            problems.append(
                "%s: developer field id(s) %s exist in source/StrongRowView.mc "
                "and are not listed in FACTS.md."
                % (MARK, ", ".join("%d (%s)" % (i, derived_fields[i])
                                   for i in missing)))
        if extra:
            problems.append(
                "%s: FACTS.md lists developer field id(s) %s that no "
                "createField call declares."
                % (MARK, ", ".join("%d (%s)" % (i, stated_fields[i])
                                   for i in extra)))
        for fid in sorted(set(stated_fields) & set(derived_fields)):
            if stated_fields[fid] != derived_fields[fid]:
                problems.append(
                    "%s devfield %d is named %r in FACTS.md and %r in "
                    "source/StrongRowView.mc."
                    % (MARK, fid, stated_fields[fid], derived_fields[fid]))

    if problems:
        print("FAIL: %d problem(s) in %s." % (len(problems), FACTS_REL))
        for p in problems:
            print("  - %s" % p)
        return 1

    print("OK: %s agrees with the tree -- container digest, %s manifest "
          "device(s), %s pinned (:test)(s), the %s ceiling note and %d "
          "developer field id->name binding(s)."
          % (FACTS_REL, facts["manifest-devices"][0], facts["pinned-tests"][0],
             facts["ceiling"][0].split()[0], len(facts["devfield"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())

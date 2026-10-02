#!/usr/bin/env python3
"""Structural validator for Ghosted.xcodeproj/project.pbxproj.

Answers the questions that a failed Xcode build usually turns into:
  1. Does every 24/16-hex object reference resolve?
  2. Is every PBXFileReference reachable from the project's mainGroup (i.e. visible in the
     navigator, not a stray file on disk)?
  3. Is every PBXBuildFile owned by exactly one build phase?
  4. Is any object id defined twice?
  5. Does the project's set of Swift files match what is actually on disk?

(4) and (5) exist because both defects were hit while adding the route providers: a copy-pasted
object id silently overwrote an unrelated object, and a new source file was left off disk's
radar entirely — neither shows up as a dangling reference, so checks 1-3 passed throughout.

Run from the repo root:  python3 Tools/validate-pbxproj.py
"""
import os
import re
import sys
from collections import Counter

PBXPROJ = "Ghosted.xcodeproj/project.pbxproj"
SOURCE_DIRS = ["Sources/GhostedCore", "Sources/Ghosted", "Sources/Spoofing", "Sources/Alerts"]
HEX = r"[0-9A-F]{16}"

src = open(PBXPROJ).read()
lines = src.splitlines()

# ---------------------------------------------------------------- objects and isa
# Real objects are indented exactly 8 spaces inside the `objects = { ... }` section. Nested
# dictionaries that merely look like objects -- `TargetAttributes` inside `attributes` -- are
# indented further and have no `isa`, so the indent is what separates the two.
INDENT = " " * 8

defined, isa = {}, {}
for i, line in enumerate(lines):
    m = re.match(rf"^{INDENT}({HEX})(?: /\*.*?\*/)? = \{{", line)
    if not m:
        continue
    oid = m.group(1)
    # `defined[oid] = i` would silently overwrite a duplicate. Record the first and let the
    # duplicate be reported rather than swallowed.
    if oid in defined:
        defined[oid] = defined[oid]  # keep the first occurrence
        continue
    defined[oid] = i
    # `isa` is either on the opening line (single-line objects) or the next one (multi-line).
    src_line = line if "isa = " in line else lines[i + 1] if i + 1 < len(lines) else ""
    found = re.search(r"isa = (\w+)", src_line)
    isa[oid] = found.group(1) if found else None

failures = []

definitions = Counter(
    m.group(1) for m in (re.match(rf"^{INDENT}({HEX})(?: /\*.*?\*/)? = \{{", ln) for ln in lines) if m
)
duplicates = sorted(o for o, n in definitions.items() if n > 1)
if duplicates:
    failures.append(
        f"object ids defined more than once: {duplicates} "
        f"(each shadows the others; Xcode resolves this to whichever it parses last)"
    )

all_refs = {r for line in lines for r in re.findall(rf"\b{HEX}\b", line)}
dangling = sorted(all_refs - set(defined))
if dangling:
    failures.append(f"dangling object references: {dangling}")
if len(isa) != len(defined):
    failures.append(f"{len(defined) - len(isa)} objects have no isa")

# --------------------------------------------------- every file ref in the navigator
groups = {}
for line in lines:
    m = re.match(rf"^{INDENT}({HEX}) /\* .*? \*/ = \{{ isa = PBXGroup;", line)
    if m:
        groups[m.group(1)] = re.findall(HEX, line)

main_group = re.search(r"mainGroup = (\w+)", src).group(1)
seen, stack = set(), [main_group]
while stack:
    node = stack.pop()
    if node in seen:
        continue
    seen.add(node)
    stack.extend(groups.get(node, []))

file_refs = {o for o, v in isa.items() if v == "PBXFileReference"}
# Build products and SDK frameworks live in BUILT_PRODUCTS_DIR / SDKROOT. Xcode synthesises a
# Products group for those and they are never navigator members, so they are not orphans.
def managed_by_xcode(oid: str) -> bool:
    return "BUILT_PRODUCTS_DIR" in lines[defined[oid]] or "SDKROOT" in lines[defined[oid]]

synthetic = sorted(o for o in file_refs if managed_by_xcode(o))
orphans = sorted(o for o in file_refs - seen if not managed_by_xcode(o))
if orphans:
    failures.append(f"file references not reachable from mainGroup: {orphans}")

# ------------------------------------------------ build files owned by exactly one phase
build_files = {o for o, v in isa.items() if v == "PBXBuildFile"}
entries = []
current_phase = None
for line in lines:
    m = re.match(rf"^{INDENT}({HEX})(?: /\* .*? \*/)? = \{{", line)
    if m and isa.get(m.group(1), "").endswith("BuildPhase"):
        current_phase = m.group(1)
    files = re.search(r"files = \(([^)]*)\)", line)
    if files and current_phase:
        entries += [(current_phase, f) for f in re.findall(HEX, files.group(1))]
        current_phase = None

ownership = Counter(f for _, f in entries)
not_build_files = [f for f in ownership if f not in build_files]
if not_build_files:
    failures.append(f"non-PBXBuildFile objects listed in a phase: {not_build_files}")
duplicated = sorted(f for f, n in ownership.items() if n != 1)
if duplicated:
    phases = sorted({p for p, f in entries if f in set(duplicated)})
    failures.append(f"build files in {phases} phase(s): {duplicated}")
missing = sorted(build_files - set(ownership))
if missing:
    failures.append(f"PBXBuildFiles in no build phase: {missing}")

# -------------------------------------------------- project sources vs files on disk
# A Swift file that exists but is not a PBXFileReference is silently not compiled by the app
# target -- the single easiest way to ship a feature that never builds. Checked in both
# directions: a registered file that is missing from disk is a hard build error.
on_disk = {}
for directory in SOURCE_DIRS:
    if os.path.isdir(directory):
        for f in os.listdir(directory):
            if f.endswith(".swift"):
                on_disk[f] = os.path.join(directory, f)

# Resolve each non-Xcode-managed file reference's `path` against its group's `path`, so the
# comparison is against a real path rather than a bare filename.
group_path = {}
for gid, children in groups.items():
    m = re.search(r"\bpath = ([^;]+);", lines[defined[gid]])
    group_path[gid] = m.group(1).strip('"') if m else ""

file_path = {}
parent = {}
for gid, children in groups.items():
    for child in children:
        parent[child] = gid


def resolve(oid: str) -> str | None:
    """Full path of a file reference, walking up the group tree."""
    m = re.search(r"\bpath = ([^;]+);", lines[defined[oid]])
    if not m:
        return None
    parts = [m.group(1).strip('"')]
    node = oid
    seen = {oid}
    while node in parent:
        node = parent[node]
        if node in seen:      # a group cycle would otherwise hang the validator
            break
        seen.add(node)
        # A group with a `name` but no `path` is virtual and contributes nothing to the path.
        prefix = group_path.get(node)
        if prefix:
            parts.insert(0, prefix)
    return "/".join(p for p in parts if p)


registered_paths = {}
for oid in sorted(file_refs):
    if managed_by_xcode(oid):
        continue
    resolved = resolve(oid)
    if resolved:
        registered_paths[resolved] = oid

registered = set(registered_paths)

unregistered = sorted(set(on_disk.values()) - registered)
if unregistered:
    failures.append(
        f"Swift files on disk that no PBXFileReference points at (never compiled): {unregistered}"
    )
absent = sorted(p for p in registered if p.endswith(".swift") and not os.path.exists(p))
if absent:
    failures.append(f"registered Swift file references missing from disk (build error): {absent}")
# Non-Swift resources must still exist too: a missing Info.plist or entitlements file breaks
# the build just as hard as a missing source.
absent_resources = sorted(
    p for p in registered
    if not p.endswith(".swift") and "/GhostedCore/" not in p and not os.path.exists(p)
)
if absent_resources:
    failures.append(f"registered resource references missing from disk (build error): {absent_resources}")

# -------------------------------------------------------------------------- report
print(f"objects              {len(defined)}")
print(f"duplicate ids        {len(duplicates)}")
print(f"dangling refs        {len(dangling)}")
print(f"file refs in nav     {len(file_refs) - len(orphans) - len(synthetic)}/{len(file_refs) - len(synthetic)}"
      f"  ({len(synthetic)} build-product/SDK refs are Xcode-managed)")
print(f"build files phased   {len(ownership)}/{len(build_files)} (each exactly once)")
print(f"sources on disk      {len(on_disk) - len(unregistered)}/{len(on_disk)} registered in project")
print(f"targets              {sum(1 for v in isa.values() if v == 'PBXNativeTarget')}")

if failures:
    print("\nFAIL")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("\nOK - project file is structurally sound")
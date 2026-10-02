#!/usr/bin/env bash
#
# Type-check the iOS-only app layer on any host with a Swift toolchain — no iOS SDK, no macOS.
#
# WHY THIS EXISTS
#   Sources/Spoofing, Sources/Alerts and the `#if os(iOS)` half of Sources/Ghosted are compiled by
#   exactly one target: the iOS app target in Ghosted.xcodeproj. `swift build` cannot see them, so
#   until `build-ipa.yml` ran, a signature slip in those files could reach master unnoticed
#   (AUDIT.md defect #2). This script closes that hole by compiling them against the stub modules
#   in ./Stubs.
#
# WHAT THIS IS NOT
#   This is NOT a build of the app. It is a type-check only: no linking, no code generation, no
#   asset catalog, no storyboard, no signing. It cannot validate that Apple's real SDK matches the
#   stubs. See README.md for exactly what it does and does not cover.
#
# WHAT IT DELIBERATELY DOES NOT CHECK
#   Two things cannot be expressed without an Objective-C runtime, so they are rewritten away below
#   and are therefore NOT verified by this script:
#     * `@objc` on the target/action methods in GhostedApp.swift
#     * `#selector(...)` (and the `@main` synthesised `UIApplicationMain` call) on AppDelegate
#   Those are still covered by the real Xcode build in .github/workflows/build-ipa.yml.
#
#   One further line is neutralised because of a *host* limitation rather than an SDK one:
#     * `URLSessionConfiguration.waitsForConnectivity` is a settable `var` on Apple platforms but
#       get-only in corelibs-foundation. `URLSessionTransport.swift` assigns it, so the
#       assignment is commented out for this check only. Everything else in that file —
#       including the `async throws` signature of `URLSession.data(for:)` and the
#       `response as? HTTPURLResponse` cast — is verified, because Linux provides those.
#       (This is why there is no FoundationNetworking stub in ./Stubs: declaring one would make
#       `URLError` ambiguous for type lookup, which hides real errors rather than modelling the
#       SDK. See Stubs/README.md.)
#
# Usage:  Tools/IOSTypeCheck/check.sh [swift-version]     (default 6)
#
set -euo pipefail

SWIFT_VERSION="${1:-6}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MODULES=(UIKit CoreLocation AVFoundation Network Security)

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

command -v swift >/dev/null || die "no 'swift' on PATH"
command -v swiftc >/dev/null || die "no 'swiftc' on PATH"

# --- 1. GhostedCore, the portable library the app layer imports ---------------------
say "Building GhostedCore"
cd "$ROOT"
swift build --target GhostedCore >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
[ -f "$BIN_DIR/Modules/GhostedCore.swiftmodule" ] || die "GhostedCore.swiftmodule not found in $BIN_DIR/Modules"
CORE_INCLUDE="$BIN_DIR/Modules"

# --- 2. Stub SDK modules ------------------------------------------------------------
say "Building stub SDK modules (swift-version $SWIFT_VERSION)"
mkdir -p "$WORK/stubs"
for m in "${MODULES[@]}"; do
    # Compiled in Swift 5 mode on purpose: the stubs exist to model the SDK's API surface, and
    # building them under the language mode under test would fail for stub-internal reasons.
    swiftc -emit-module -emit-module-path "$WORK/stubs/$m.swiftmodule" \
        -module-name "$m" -swift-version 5 -suppress-warnings "$HERE/Stubs/$m.swift"
done

# --- 3. Rewrite the iOS sources so they compile on this host -----------------------
# `#if os(iOS)` is false on Linux/macOS, so the app layer would compile to nothing and the check
# would pass vacuously. Flip it on. This is a text rewrite, NOT a build of the iOS target.
say "Preparing sources"
mkdir -p "$WORK/src"
for f in "$ROOT"/Sources/Ghosted/*.swift "$ROOT"/Sources/Spoofing/*.swift "$ROOT"/Sources/Alerts/*.swift; do
    # `sed` cannot match `#selector(...)` generically without knowing the method names, so this
    # rewrites *every* `#selector(<identifier>)` — the method always has the same shape — and
    # strips `@objc` from any target/action method. Rewriting by pattern rather than by an
    # enumerated list means a new `@objc` handler is covered the moment it is written, instead
    # of silently going unchecked because someone forgot to update this script.
    sed -e 's/^#if os(iOS)$/#if true/' \
        -e 's/#selector(\([A-Za-z_][A-Za-z0-9_]*\))/Selector()/g' \
        -e 's/@objc[[:space:]]\{1,\}private[[:space:]]\{1,\}func/@objc_removed private func/' \
        -e 's/^@main$//' \
        -e 's/^\( *\)configuration.waitsForConnectivity = false.*$/\1\/\/ harness: corelibs-foundation makes this get-only/' \
        "$f" \
    | sed -e 's/^\( *\)@objc_removed private func/\1private func/' \
          -e 's/^final class AppDelegate: UIResponder, UIApplicationDelegate {/final class AppDelegate: UIResponder, UIApplicationDelegate { static func main() {}/' \
    > "$WORK/src/$(basename "$f")"
done

if ! grep -q '#if true' "$WORK/src/GhostedApp.swift"; then
    die "the '#if os(iOS)' rewrite did not apply — the check would pass vacuously"
fi
# Same reasoning for the `#selector` rewrite: if any survive, the check is about to fail on an
# Objective-C-runtime limitation and would look like a real type error.
if grep -rn '#selector' "$WORK/src" >/dev/null 2>&1; then
    die "a #selector survived the rewrite — expected an Objective-C-runtime error, not a clean pass"
fi

# --- 4. Type-check -------------------------------------------------------------------
say "Type-checking the app layer (swift-version $SWIFT_VERSION)"
EXTRA=()
if [ "$SWIFT_VERSION" = "5" ]; then
    EXTRA+=(-strict-concurrency=minimal)
fi

set +e
swiftc -typecheck -swift-version "$SWIFT_VERSION" "${EXTRA[@]}" \
    -I "$WORK/stubs" -I "$CORE_INCLUDE" "$WORK"/src/*.swift
STATUS=$?
set -e

if [ $STATUS -ne 0 ]; then
    die "app layer does not type-check under Swift $SWIFT_VERSION"
fi

say "OK — app layer type-checks under Swift $SWIFT_VERSION"
echo "    Sources/Spoofing, Sources/Alerts, Sources/Ghosted (iOS branch)"
echo "    Note: @objc / #selector / @main-on-AppDelegate are NOT checked here (no ObjC runtime)."
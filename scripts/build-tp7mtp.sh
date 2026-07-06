#!/usr/bin/env bash
set -euo pipefail

# Builds libtp7mtp.dylib from source and signs it with the team identity.
# Run from the repo root inside `nix develop`:
#   nix develop
#   ./scripts/build-tp7mtp.sh
#
# Or without entering the shell:
#   nix develop .#default --command ./scripts/build-tp7mtp.sh

if ! pkg-config --exists libusb-1.0 2>/dev/null; then
    echo "ERROR: libusb-1.0 not found. Run inside 'nix develop'." >&2
    exit 1
fi

# Clear stale build cache if Go version changed since last build
CACHE_VERSION_FILE="${GOPATH:-$HOME/go}/.tp7mtp-go-version"
CURRENT_GO="$(go version)"
if [ -f "$CACHE_VERSION_FILE" ] && [ "$(cat "$CACHE_VERSION_FILE")" != "$CURRENT_GO" ]; then
    echo "Go version changed, clearing build cache..."
    go clean -cache
fi
echo "$CURRENT_GO" > "$CACHE_VERSION_FILE"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="$REPO_ROOT/native/tp7mtp"
VENDOR_DIR="$REPO_ROOT/Vendor/TP7MTP"

# Team identity for signing - set via env or default to ad-hoc
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

echo "Building libtp7mtp.dylib..."
cd "$NATIVE_DIR"

CGO_ENABLED=1 go build -a \
    -buildmode=c-shared \
    -o "$VENDOR_DIR/libtp7mtp.dylib" \
    .

echo "Fixing install names for vendored dependencies..."
install_name_tool -id \
    "@rpath/libtp7mtp.dylib" \
    "$VENDOR_DIR/libtp7mtp.dylib"

# Rewrite Nix store paths to @rpath so the dylib works on machines without Nix
install_name_tool -change \
    "$(otool -L "$VENDOR_DIR/libtp7mtp.dylib" | grep libusb | awk '{print $1}')" \
    "@rpath/libusb-1.0.0.dylib" \
    "$VENDOR_DIR/libtp7mtp.dylib"
install_name_tool -change \
    "$(otool -L "$VENDOR_DIR/libtp7mtp.dylib" | grep libresolv | awk '{print $1}')" \
    "/usr/lib/libresolv.9.dylib" \
    "$VENDOR_DIR/libtp7mtp.dylib"

echo "Signing libtp7mtp.dylib..."
codesign --force --sign "$CODESIGN_IDENTITY" \
    --options runtime \
    "$VENDOR_DIR/libtp7mtp.dylib"

# Also sign libusb if present and ad-hoc
if [ -f "$VENDOR_DIR/libusb-1.0.0.dylib" ]; then
    LIBUSB_SIG=$(codesign -d --verbose=2 "$VENDOR_DIR/libusb-1.0.0.dylib" 2>&1 || true)
    if echo "$LIBUSB_SIG" | grep -q "adhoc"; then
        echo "Signing libusb-1.0.0.dylib..."
        codesign --force --sign "$CODESIGN_IDENTITY" \
            --options runtime \
            "$VENDOR_DIR/libusb-1.0.0.dylib"
    fi
fi

echo "Verifying signatures..."
codesign -dvv "$VENDOR_DIR/libtp7mtp.dylib" 2>&1 | grep -E "Authority|TeamIdentifier|Signature"
codesign -dvv "$VENDOR_DIR/libusb-1.0.0.dylib" 2>&1 | grep -E "Authority|TeamIdentifier|Signature"

echo "Done."

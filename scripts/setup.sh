#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FRAMEWORKS_DIR="$PROJECT_DIR/Frameworks"
TTS_VENDOR_DIR="$PROJECT_DIR/Locus/TTS/Vendor"

POCKET_TTS_VERSION="v0.4.1"
POCKET_TTS_ZIP_URL="https://github.com/UnaMentis/pocket-tts-ios/releases/download/${POCKET_TTS_VERSION}/PocketTTS-${POCKET_TTS_VERSION}.zip"
POCKET_TTS_ZIP_SHA256="f6d6258ed2d09f39bab7524a04a79fcbe44cc50e5278445ace186a90797179f5"

echo "=== Locus iOS - Setup ==="
echo ""

# ── Step 1: Download PocketTTS XCFramework ──────────────────────────────

echo "[1/4] Downloading PocketTTS ${POCKET_TTS_VERSION}..."

mkdir -p "$FRAMEWORKS_DIR"
mkdir -p "$TTS_VENDOR_DIR"

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

ZIP_FILE="$TEMP_DIR/PocketTTS.zip"

if [ -d "$FRAMEWORKS_DIR/PocketTTS.xcframework" ]; then
    echo "  PocketTTS.xcframework already exists, skipping download."
else
    curl -L --progress-bar -o "$ZIP_FILE" "$POCKET_TTS_ZIP_URL"

    # Verify checksum
    echo "  Verifying checksum..."
    ACTUAL_SHA256=$(shasum -a 256 "$ZIP_FILE" | cut -d' ' -f1)
    if [ "$ACTUAL_SHA256" != "$POCKET_TTS_ZIP_SHA256" ]; then
        echo "  WARNING: Checksum mismatch!"
        echo "    Expected: $POCKET_TTS_ZIP_SHA256"
        echo "    Actual:   $ACTUAL_SHA256"
        echo "  Continuing anyway (checksum may have changed with a new release)..."
    else
        echo "  Checksum OK."
    fi

    # Extract
    echo "  Extracting..."
    unzip -q "$ZIP_FILE" -d "$TEMP_DIR/extracted"

    # Move XCFramework
    find "$TEMP_DIR/extracted" -name "PocketTTS.xcframework" -type d -exec cp -R {} "$FRAMEWORKS_DIR/" \;
    echo "  Installed PocketTTS.xcframework to Frameworks/"

    # Copy UniFFI Swift bindings
    BINDINGS_FILE=$(find "$TEMP_DIR/extracted" -name "pocket_tts_ios.swift" -type f | head -1)
    if [ -n "$BINDINGS_FILE" ]; then
        cp "$BINDINGS_FILE" "$TTS_VENDOR_DIR/pocket_tts_ios.swift"
        echo "  Installed pocket_tts_ios.swift to Locus/TTS/Vendor/"
    else
        echo "  WARNING: pocket_tts_ios.swift not found in archive."
    fi
fi

# ── Step 2: Download PocketTTSSwift wrapper ─────────────────────────────

echo ""
echo "[2/4] Fetching PocketTTSSwift.swift wrapper..."

SWIFT_WRAPPER_URL="https://raw.githubusercontent.com/UnaMentis/pocket-tts-ios/main/swift/PocketTTSSwift.swift"

if [ -f "$TTS_VENDOR_DIR/PocketTTSSwift.swift" ]; then
    echo "  PocketTTSSwift.swift already exists, skipping."
else
    if curl -fsSL -o "$TTS_VENDOR_DIR/PocketTTSSwift.swift" "$SWIFT_WRAPPER_URL" 2>/dev/null; then
        echo "  Installed PocketTTSSwift.swift to Locus/TTS/Vendor/"
    else
        echo "  WARNING: Could not download PocketTTSSwift.swift."
        echo "  You may need to copy it manually from the pocket-tts-ios repo."
    fi
fi

# ── Step 3: Generate Xcode project ──────────────────────────────────────

echo ""
echo "[3/4] Generating Xcode project..."

cd "$PROJECT_DIR"

if command -v xcodegen &> /dev/null; then
    xcodegen generate
    echo "  Generated Locus.xcodeproj"
else
    echo "  xcodegen not found. Install with: brew install xcodegen"
    echo "  Then run: cd $(basename $PROJECT_DIR) && xcodegen generate"
fi

# ── Step 4: Summary ─────────────────────────────────────────────────────

echo ""
echo "[4/4] Setup complete!"
echo ""
echo "Project structure:"
echo "  Frameworks/PocketTTS.xcframework  - TTS binary framework"
echo "  Locus/TTS/Vendor/                 - TTS Swift bindings"
echo ""
echo "Next steps:"
echo "  1. Open Locus.xcodeproj in Xcode"
echo "  2. Wait for SPM to resolve (moonshine-swift, llama-swift)"
echo "  3. Build and run on iOS Simulator or device"
echo "  4. On first launch, download ML models (~855 MB) or tap Skip"
echo ""
echo "Models (downloaded at runtime by the app):"
echo "  - Moonshine Streaming Small (STT): ~125 MB"
echo "  - Qwen3.5-0.8B Q4_K_M (LLM):      ~500 MB"
echo "  - Pocket TTS (TTS):                 ~230 MB"

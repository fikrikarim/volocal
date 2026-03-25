#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Volocal iOS - Setup ==="
echo ""

# ── Step 1: Generate Xcode project ──────────────────────────────────────

echo "[1/2] Generating Xcode project..."

cd "$PROJECT_DIR"

if command -v xcodegen &> /dev/null; then
    xcodegen generate
    echo "  Generated Volocal.xcodeproj"
else
    echo "  xcodegen not found. Install with: brew install xcodegen"
    echo "  Then run: cd $(basename $PROJECT_DIR) && xcodegen generate"
fi

# ── Step 2: Summary ─────────────────────────────────────────────────────

echo ""
echo "[2/2] Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Open Volocal.xcodeproj in Xcode"
echo "  2. Wait for SPM to resolve (moonshine-swift, llama-swift, FluidAudio)"
echo "  3. Build and run on iOS Simulator or device"
echo "  4. On first launch, download STT + LLM models (~798 MB) or tap Skip"
echo "     TTS models are auto-downloaded by FluidAudio on first use."
echo ""
echo "Models:"
echo "  - Moonshine Medium Streaming (STT): ~290 MB (downloaded by app)"
echo "  - Qwen3.5-0.8B Q4_K_M (LLM):       ~508 MB (downloaded by app)"
echo "  - FluidAudio TTS:                    ~601 MB (auto-downloaded by FluidAudio)"

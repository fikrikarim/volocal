#!/bin/bash
# Serves model files from your Mac over local WiFi.
# Run this, then tap "Download Models" in the app on your iPhone.
# Note: TTS models are managed by FluidAudio and not served here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SERVE_DIR="$PROJECT_DIR/.model-server"
PORT=8080

# Get local IP
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")

echo "=== Locus Model Server ==="
echo ""

# Create serving directory with the expected file structure
rm -rf "$SERVE_DIR"
mkdir -p "$SERVE_DIR/moonshine-medium-streaming"

# Symlink Moonshine models
MOONSHINE_SRC="$HOME/Library/Caches/moonshine_voice/download.moonshine.ai/model/medium-streaming-en/quantized"
if [ -d "$MOONSHINE_SRC" ]; then
    for f in encoder.ort decoder_kv.ort cross_kv.ort frontend.ort adapter.ort tokenizer.bin streaming_config.json; do
        ln -sf "$MOONSHINE_SRC/$f" "$SERVE_DIR/moonshine-medium-streaming/$f" 2>/dev/null || true
    done
    echo "[OK] Moonshine Medium Streaming"
else
    echo "[SKIP] Moonshine models not found at $MOONSHINE_SRC"
fi

# Symlink LLM model
LLM_SRC="$PROJECT_DIR/models/Qwen3.5-0.8B-Q4_K_M.gguf"
if [ -f "$LLM_SRC" ]; then
    ln -sf "$LLM_SRC" "$SERVE_DIR/Qwen3.5-0.8B-Q4_K_M.gguf"
    echo "[OK] Qwen3.5-0.8B Q4_K_M GGUF"
else
    echo "[SKIP] LLM model not found at $LLM_SRC"
fi

echo ""
echo "Serving at: http://$LOCAL_IP:$PORT"
echo ""
echo "Set this URL in the app's ModelManager.localServerURL"
echo "or update the download URLs to point here."
echo ""
echo "Note: TTS models are auto-downloaded by FluidAudio (not served here)."
echo ""
echo "Press Ctrl+C to stop."
echo ""

cd "$SERVE_DIR"

# Use a multi-threaded Python server for fast local transfers
python3 -c "
from http.server import HTTPServer, SimpleHTTPRequestHandler
from socketserver import ThreadingMixIn

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

class LargeFileHandler(SimpleHTTPRequestHandler):
    # 1 MB read buffer (default is 64 KB)
    def copyfile(self, source, outputfile):
        import shutil
        shutil.copyfileobj(source, outputfile, length=1024*1024)

server = ThreadedHTTPServer(('0.0.0.0', $PORT), LargeFileHandler)
print(f'Serving on port $PORT (multi-threaded)...')
server.serve_forever()
"

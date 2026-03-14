#!/bin/bash
# Serves model files from your Mac over local WiFi.
# Run this, then tap "Download Models" in the app on your iPhone.
# Note: STT and TTS models are auto-downloaded by FluidAudio (not served here).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SERVE_DIR="$PROJECT_DIR/.model-server"
PORT=8080

# Get local IP
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")

echo "=== Locus Model Server ==="
echo ""

# Create serving directory
rm -rf "$SERVE_DIR"
mkdir -p "$SERVE_DIR"

# Symlink LLM model
LLM_SRC="$PROJECT_DIR/models/Qwen_Qwen3.5-2B-Q4_K_S.gguf"
if [ -f "$LLM_SRC" ]; then
    ln -sf "$LLM_SRC" "$SERVE_DIR/Qwen_Qwen3.5-2B-Q4_K_S.gguf"
    echo "[OK] Qwen3.5-2B Q4_K_S GGUF (~1.26 GB)"
else
    echo "[SKIP] LLM model not found at $LLM_SRC"
    echo "       Download from: https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF"
    echo "       Place at: $LLM_SRC"
fi

echo ""
echo "Serving at: http://$LOCAL_IP:$PORT"
echo ""
echo "Set this URL in the app's ModelManager.baseURL"
echo ""
echo "Note: STT and TTS models are auto-downloaded by FluidAudio (not served here)."
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

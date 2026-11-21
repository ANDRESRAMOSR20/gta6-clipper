#!/usr/bin/env bash
# GTA 6 Clipper setup: checks what this computer needs (macOS or Arch-based Linux), installs what's missing, says when it's ready.
# Safe to re-run any time.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$SKILL_DIR/.venv"
MODELS="$SKILL_DIR/models"
mkdir -p "$MODELS"
ok()   { printf "  [ok]      %s\n" "$1"; }
inst() { printf "  [install] %s\n" "$1"; }
fail() { printf "  [MISSING] %s\n" "$1"; FAILED=1; }
FAILED=0

echo "GTA 6 Clipper setup"
OS="$(uname)"
if [[ "$OS" != "Darwin" && "$OS" != "Linux" ]]; then
  echo "This version supports macOS and Linux. On Windows, install the Windows version instead:"
  echo "  Open PowerShell (Start -> type PowerShell) and paste:"
  echo "  irm https://raw.githubusercontent.com/vossashtonai/gta6-clipper-windows/main/install.ps1 | iex"
  echo "  (or see https://github.com/vossashtonai/gta6-clipper-windows)"
  exit 1
fi

# 1. Package manager: Homebrew on macOS, pacman on Arch-based Linux (Arch, CachyOS, EndeavourOS, Manjaro)
if [[ "$OS" == "Darwin" ]]; then
  if command -v brew >/dev/null 2>&1; then ok "Homebrew"; else
    fail "Homebrew (install from https://brew.sh then re-run setup)"; exit 1; fi
  PKG_INSTALL=(brew install)
elif command -v pacman >/dev/null 2>&1; then
  ok "pacman"
  # ponytail: Arch-only; add apt/dnf branches when someone needs them
  PKG_INSTALL=(sudo pacman -S --needed --noconfirm)
else
  fail "pacman (only Arch-based Linux is supported; install ffmpeg, whisper-cpp and deno by hand, then re-run setup)"
  PKG_INSTALL=(false)
fi

# 2. Command-line tools: ffmpeg (cutting/encoding), whisper-cpp (local transcript), deno (YouTube downloads)
for pair in "ffmpeg:ffmpeg" "whisper-cli:whisper-cpp" "deno:deno"; do
  bin="${pair%%:*}"; pkg="${pair##*:}"
  if command -v "$bin" >/dev/null 2>&1; then ok "$pkg"; else
    inst "$pkg"; "${PKG_INSTALL[@]}" "$pkg" >/dev/null 2>&1 && command -v "$bin" >/dev/null 2>&1 && ok "$pkg" \
      || fail "$pkg (${PKG_INSTALL[*]} $pkg)"; fi
done

# 2b. NVIDIA GPU on Linux: CUDA backend so whisper-cpp transcribes on the GPU instead of the CPU
if [[ "$OS" == "Linux" ]] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  if [[ -f /usr/lib/ggml/libggml-cuda.so ]]; then ok "ggml-cuda (Whisper on GPU)"; else
    inst "ggml-cuda (Whisper on GPU; pulls in CUDA, a few GB)"
    "${PKG_INSTALL[@]}" ggml-cuda >/dev/null 2>&1 && ok "ggml-cuda (Whisper on GPU)" \
      || printf "  [skip]    ggml-cuda failed; Whisper will run on the CPU (slower). Try: %s ggml-cuda\n" "${PKG_INSTALL[*]}"; fi
fi

# 3. uv (fast Python + venv manager)
if command -v uv >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/uv" ]]; then ok "uv"; else
  inst "uv"; curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 && ok "uv" || fail "uv"; fi
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"

# 4. Python environment: yt-dlp (always latest, sites change weekly), OpenCV (facecam finder), Pillow (captions)
if [[ ! -x "$VENV/bin/python" ]]; then inst "Python 3.12 environment"; "$UV" venv --python 3.12 "$VENV" >/dev/null 2>&1; fi
"$UV" pip install --python "$VENV/bin/python" -q -U "yt-dlp[default]" opencv-python-headless pillow numpy >/dev/null 2>&1 \
  && ok "Python packages (yt-dlp, opencv, pillow, numpy)" || fail "Python packages"

# 5. Whisper model (speech -> text, runs on this computer). Multilingual, so English and Spanish streams
#    both work (language is auto-detected per stream). Reuse an existing one if present.
WHISPER_MODEL=""
for m in "$MODELS/ggml-small.bin" "$HOME/.cache/whisper-cpp/ggml-small.bin"; do
  [[ -s "$m" ]] && WHISPER_MODEL="$m" && break; done
if [[ -z "$WHISPER_MODEL" ]]; then
  inst "Whisper small multilingual model (~465 MB)"
  curl -fL -s -o "$MODELS/ggml-small.bin" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin \
    && WHISPER_MODEL="$MODELS/ggml-small.bin" || fail "whisper model"
fi
[[ -n "$WHISPER_MODEL" ]] && ok "Whisper model: $WHISPER_MODEL"

# 6. Face detector model (YuNet, ~230 KB) used to find the facecam box
YUNET="$MODELS/face_detection_yunet_2023mar.onnx"
if [[ ! -f "$YUNET" ]]; then
  inst "YuNet face detector"
  curl -L -s -o "$YUNET" https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx || fail "YuNet model"
fi
[[ -s "$YUNET" ]] && ok "Face detector" || fail "Face detector"

# 7. Caption font: Arial Black (macOS ships it), else the first heavy font fontconfig finds
FONT=""
if [[ -f "/System/Library/Fonts/Supplemental/Arial Black.ttf" ]]; then
  FONT="/System/Library/Fonts/Supplemental/Arial Black.ttf"
elif command -v fc-list >/dev/null 2>&1; then
  for q in "Arial Black" "Impact" "Anton" "DejaVu Sans:style=Bold" "Liberation Sans:style=Bold"; do
    FONT="$(fc-list -f '%{file}\n' "$q" | head -n1)"; [[ -n "$FONT" ]] && break; done
fi
if [[ -n "$FONT" ]]; then ok "Caption font: $FONT"; else
  fail "Caption font (Linux: sudo pacman -S ttf-dejavu, or install Anton / ttf-ms-fonts for the Mac look)"; fi

# 8. Free space check: audio-only download keeps this small, but warn early
FREE_GB=$(( $(df -Pk "$SKILL_DIR" | awk 'NR==2{print $4}') / 1048576 ))
if (( FREE_GB < 3 )); then echo "  [warn]    Only ${FREE_GB} GB free. Each stream needs ~0.5-1 GB while it runs."; else ok "Disk space (${FREE_GB} GB free)"; fi

cat > "$SKILL_DIR/config.json" <<EOF
{"whisper_model": "$WHISPER_MODEL", "yunet_model": "$YUNET", "font": "$FONT"}
EOF

if [[ $FAILED -eq 0 ]]; then
  date > "$SKILL_DIR/.ready"
  echo; echo "READY. Say: clip this stream <link>   or   find me today's biggest GTA 6 streams and clip them"
else
  rm -f "$SKILL_DIR/.ready"; echo; echo "NOT READY: fix the [MISSING] items above and re-run setup."; exit 1
fi

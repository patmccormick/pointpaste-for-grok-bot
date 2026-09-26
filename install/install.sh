#!/usr/bin/env bash
# PointTalk installer (Apple Silicon Mac).
# Builds whisper-cli + nowplaying-cli into ~/.hammerspoon/local, downloads the
# ggml-base.en model into ~/.hammerspoon/models, installs ffmpeg (and cmake) with
# Homebrew if missing, and copies the Hammerspoon Lua files. Safe to re-run:
# it never overwrites an existing ~/.hammerspoon/voice-webhook.json.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HS="$HOME/.hammerspoon"
LOCAL="$HS/local"
SRC="$HS/src"
MODELS="$HS/models"
MODEL_FILE="$MODELS/ggml-base.en.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp.git"      # formerly github.com/ggerganov/whisper.cpp
NOWPLAYING_REPO="https://github.com/kirtan-shah/nowplaying-cli.git"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. Preflight -------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ "$(uname -m)" == "arm64" ]] || warn "Not Apple Silicon; the build may work but is untested (Lua expects Homebrew ffmpeg in /opt/homebrew or /usr/local)."
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools missing. Run: xcode-select --install   (then re-run this script)"
if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -x "$b" ]] && eval "$("$b" shellenv)"; done
fi
command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it from https://brew.sh then re-run."
command -v git  >/dev/null 2>&1 || brew install git

mkdir -p "$LOCAL/bin" "$SRC" "$MODELS"

# --- 1. Homebrew tools ----------------------------------------------------------
say "PointTalk: checking ffmpeg / cmake"
if [[ -x /opt/homebrew/bin/ffmpeg || -x /usr/local/bin/ffmpeg ]]; then
  echo "ffmpeg: already installed"
else
  brew install ffmpeg
fi
command -v cmake >/dev/null 2>&1 || brew install cmake

# --- 2. whisper.cpp -> ~/.hammerspoon/local/bin/whisper-cli ---------------------
say "Building whisper-cli (Metal, static)"
if [[ -x "$LOCAL/bin/whisper-cli" && "${REBUILD:-0}" != "1" ]]; then
  echo "whisper-cli already present (set REBUILD=1 to rebuild)"
else
  if [[ -d "$SRC/whisper.cpp/.git" ]]; then
    git -C "$SRC/whisper.cpp" pull --ff-only || warn "could not update whisper.cpp; building existing checkout"
  else
    git clone --depth 1 "$WHISPER_REPO" "$SRC/whisper.cpp"
  fi
  cmake -S "$SRC/whisper.cpp" -B "$SRC/whisper.cpp/build" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
  cmake --build "$SRC/whisper.cpp/build" --config Release -j "$(sysctl -n hw.ncpu)" --target whisper-cli
  install -m 755 "$SRC/whisper.cpp/build/bin/whisper-cli" "$LOCAL/bin/whisper-cli"
fi

# --- 3. Model -> ~/.hammerspoon/models/ggml-base.en.bin (~148 MB) ----------------
say "Downloading ggml-base.en model"
if [[ -s "$MODEL_FILE" ]] && [[ $(stat -f%z "$MODEL_FILE") -gt 100000000 ]]; then
  echo "model already present"
else
  curl -L --fail --progress-bar -o "$MODEL_FILE.part" "$MODEL_URL"
  mv "$MODEL_FILE.part" "$MODEL_FILE"
fi

# --- 4. nowplaying-cli -> ~/.hammerspoon/local (pauses media while you talk) ------
# Built from source so the MediaRemote helper (needed on recent macOS) is installed
# next to the binary. Falls back to Homebrew's nowplaying-cli if the build fails.
say "Installing nowplaying-cli"
if [[ -x "$LOCAL/bin/nowplaying-cli" && "${REBUILD:-0}" != "1" ]]; then
  echo "nowplaying-cli already present"
else
  if { [[ -d "$SRC/nowplaying-cli/.git" ]] || git clone --depth 1 "$NOWPLAYING_REPO" "$SRC/nowplaying-cli"; } \
     && make -C "$SRC/nowplaying-cli" install PREFIX="$LOCAL"; then
    echo "nowplaying-cli built into $LOCAL"
  else
    warn "source build failed; trying Homebrew"
    command -v nowplaying-cli >/dev/null 2>&1 || brew install nowplaying-cli
    ln -sf "$(command -v nowplaying-cli)" "$LOCAL/bin/nowplaying-cli"
  fi
fi

# --- 5. Hammerspoon files ------------------------------------------------------------
say "Copying Hammerspoon files"
STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$HS/voice_ptt.lua" ]] && ! cmp -s "$KIT_DIR/hammerspoon/voice_ptt.lua" "$HS/voice_ptt.lua"; then
  cp "$HS/voice_ptt.lua" "$HS/voice_ptt.lua.bak-$STAMP"
  echo "backed up existing voice_ptt.lua -> voice_ptt.lua.bak-$STAMP"
fi
install -m 644 "$KIT_DIR/hammerspoon/voice_ptt.lua" "$HS/voice_ptt.lua"

if [[ -f "$HS/voice-webhook.json" ]]; then
  echo "voice-webhook.json exists: left untouched"
else
  install -m 600 "$KIT_DIR/hammerspoon/voice-webhook.example.json" "$HS/voice-webhook.json"
  echo "created ~/.hammerspoon/voice-webhook.json (fill in url + authorization)"
fi

if [[ ! -f "$HS/init.lua" ]]; then
  cp "$KIT_DIR/hammerspoon/init.lua" "$HS/init.lua"
  echo "created ~/.hammerspoon/init.lua"
elif ! grep -q 'require("voice_ptt")' "$HS/init.lua"; then
  cp "$HS/init.lua" "$HS/init.lua.bak-$STAMP"
  printf '\n' >> "$HS/init.lua"
  cat "$KIT_DIR/hammerspoon/init.lua" >> "$HS/init.lua"
  echo "appended voice_ptt to init.lua (backup: init.lua.bak-$STAMP)"
else
  echo "init.lua already loads voice_ptt"
fi

# --- 6. Smoke check -----------------------------------------------------------------
say "Checking"
"$LOCAL/bin/whisper-cli" --help >/dev/null 2>&1 && echo "whisper-cli OK" || warn "whisper-cli did not run"
"$LOCAL/bin/nowplaying-cli" get title >/dev/null 2>&1 && echo "nowplaying-cli OK" || warn "nowplaying-cli did not run (media pause is optional)"
[[ -d /Applications/Hammerspoon.app ]] || warn "Hammerspoon not found in /Applications. Install it: brew install --cask hammerspoon"

cat <<MSG

PointTalk installed. Next:
  1. Edit ~/.hammerspoon/voice-webhook.json  (url + "Bearer <your key>")
  2. Open Hammerspoon > Reload Config, and grant Accessibility, Microphone and
     Automation (Brave) when macOS asks. See README.md.
  3. Hold Right Option, speak, release.
MSG

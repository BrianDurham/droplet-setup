#!/usr/bin/env bash
set -euo pipefail

# -------- CONFIG --------
WHISPER_PY="${WHISPER_PY:-/opt/whisper-venv/bin/python3}"
MODEL="${MODEL:-small}"     # default model
DEVICE="${DEVICE:-}"        # honor if user set, otherwise auto-detect
WORDTS="${WORDTS:-false}"   # set TRUE for word-level timestamps
ERRLOG="/tmp/whisper_last_error.log"

# -------- ARGS ----------
if [ "$#" -lt 1 ]; then
  echo "Usage: $(basename "$0") <input_audio> [output_basename]"
  echo "Example: $(basename "$0") meeting.wav"
  exit 1
fi

INPUT="$1"
BASE="${2:-$(basename "$INPUT" | sed 's/\.[^.]*$//')}"

# check whisper python exists
if [ ! -x "$WHISPER_PY" ]; then
  echo "ERROR: WHISPER_PY='$WHISPER_PY' not executable. Please set WHISPER_PY to your venv python."
  exit 2
fi

# -------- DETECT DEVICE using the WHISPER_PY INTERPRETER --------
DEVICE="$("$WHISPER_PY" - <<'PY'
import os, sys
env = os.getenv("DEVICE")
try:
    import torch
except Exception:
    # cannot import torch -> default to cpu unless user specified a non-cuda device
    if env:
        print(env)
    else:
        print("cpu")
    sys.exit(0)

if env:
    env_low = env.lower()
    if env_low.startswith("cuda") and not torch.cuda.is_available():
        # requested CUDA not available -> fall back to cpu
        print("cpu")
    else:
        print(env)
else:
    print("cuda" if torch.cuda.is_available() else "cpu")
PY
)"

echo "==> Whisper run"
echo "    Model:  $MODEL"
echo "    Device: $DEVICE"
echo "    Input:  $INPUT"
echo "    Output: $BASE.*"

# helper to run whisper and capture errors
run_whisper() {
  local dev="$1"
  # remove old error log
  rm -f "$ERRLOG"
  set +e
  "$WHISPER_PY" -m whisper "$INPUT" \
      --model "$MODEL" \
      --device "$dev" \
      --output_format all \
      $( [ "$WORDTS" = "true" ] && echo "--word_timestamps True" )
  local rc=$?
  set -e
  return $rc
}

# Attempt run on the chosen device. If it fails and device != cpu, collect diagnostics and retry on CPU.
if run_whisper "$DEVICE"; then
  echo "==> Completed on $DEVICE"
else
  rc=$?
  echo "==> Initial run failed (exit $rc) on device '$DEVICE'."

  # If we failed while using a non-cpu device, collect diagnostics to help debugging:
  if [ "${DEVICE,,}" != "cpu" ]; then
    echo "---- GPU Diagnostics ----"
    echo "nvidia-smi output:"
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi || true
    else
      echo "nvidia-smi not found"
    fi

    echo
    echo "Python CUDA diagnostics (from venv):"
    "$WHISPER_PY" - <<'PY' || true
import sys
try:
    import torch
    print("torch:", torch.__version__)
    print("torch.version.cuda:", torch.version.cuda)
    print("torch.cuda.is_available():", torch.cuda.is_available())
    if torch.cuda.is_available():
        try:
            print("cuda device:", torch.cuda.get_device_name(0))
        except Exception as e:
            print("cuda device name error:", e)
except Exception as e:
    print("ERROR checking torch:", e)
PY

    echo
    echo "---- end diagnostics ----"
  fi

  # Try retry on CPU
  echo "==> Retrying on cpu..."
  if run_whisper cpu; then
    echo "==> Completed on cpu"
  else
    rc2=$?
    echo "==> Retry on cpu failed (exit $rc2). See above diagnostics."
    exit $rc2
  fi
fi

# -------- Rename outputs to clean client-friendly names -------
[ -f "$BASE.txt" ] || mv "${INPUT}.txt"  "$BASE.txt"  || true
[ -f "$BASE.srt" ] || mv "${INPUT}.srt"  "$BASE.srt"  || true
[ -f "$BASE.vtt" ] || mv "${INPUT}.vtt"  "$BASE.vtt"  || true
[ -f "$BASE.json" ] || mv "${INPUT}.json" "$BASE.json" || true

echo "==> Done!"
echo "Files generated:"
echo "  $BASE.txt"
echo "  $BASE.srt"
echo "  $BASE.vtt"
echo "  $BASE.json"


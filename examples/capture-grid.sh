#!/usr/bin/env bash
#
# capture-grid — record a simulator animation while triggering it, auto-locate
# the motion, and emit ONE contact-sheet PNG of the frames (+ the raw .mov).
#
# Solves the "sub-second animation" gap: screenshots fire too slowly to sample a
# <3s animation, and hunting for the right slice of a screen recording by hand
# (mapping wall-clock to video time) wastes iterations. This records WHILE it
# fires the trigger — so it knows the offset — then finds the busiest window and
# tiles it into a single image you (or an agent) can read at a glance.
#
# Capture is just `xcrun simctl io recordVideo` (real 30-60fps — plenty for a
# sub-second animation). The value is correlation + extraction, not the capture.
#
# Usage:
#   capture-grid.sh --driver '<shell that taps to trigger>' [options]
#
# Options:
#   --driver <cmd>     shell run AFTER recording starts; performs the taps that
#                      navigate to + fire the animation (e.g. a series of `wand tap`).
#   --settle <sec>     keep recording this long AFTER the driver returns, to catch
#                      interstitials + the animation itself (default 14).
#   --window <sec>     length of the slice to tile into the grid (default 3.0).
#   --fps <n>          frames/sec sampled into the grid (default 12).
#   --cols <n>         grid columns (default 6; rows derived from frame count).
#   --at <sec>         explicit slice start (skips auto-detect; use when detect misses).
#   --after <sec>      when auto-detecting, ignore motion before driver-end + this
#                      (default 0 — i.e. only look after the driver finished).
#   --out <basename>   output path base (default: $TMPDIR/capture-<date>).
#   --udid <udid>      target sim (default: the booted one).
#   --keep-frames      keep the individual extracted frames (default: just grid+mov).
#
# Outputs (prints both paths):  <out>.mov   <out>-grid.png
#
# Deps: ffmpeg, xcrun (Xcode). Auto-locate prefers python3+PIL; without it,
# falls back to the LAST <window>s of the recording (pass --at to be exact).

set -euo pipefail

DRIVER=""; SETTLE=14; WINDOW=3.0; FPS=12; COLS=6; AT=""; AFTER=0
OUT=""; UDID=""; KEEP_FRAMES=0; FROM_MOV=""

while [ $# -gt 0 ]; do
  case "$1" in
    --driver) DRIVER="$2"; shift 2;;
    --settle) SETTLE="$2"; shift 2;;
    --window) WINDOW="$2"; shift 2;;
    --fps) FPS="$2"; shift 2;;
    --cols) COLS="$2"; shift 2;;
    --at) AT="$2"; shift 2;;
    --after) AFTER="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --udid) UDID="$2"; shift 2;;
    --from-mov) FROM_MOV="$2"; shift 2;;   # re-slice an existing recording (skip record+drive)
    --keep-frames) KEEP_FRAMES=1; shift;;
    -h|--help) sed -n '2,46p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v ffmpeg >/dev/null || { echo "need ffmpeg" >&2; exit 1; }

# Resolve target sim.
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl list devices booted -j 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next((x["udid"] for v in d["devices"].values() for x in v if x.get("state")=="Booted"),""))' 2>/dev/null || true)
fi
[ -n "$UDID" ] || { echo "no booted simulator (pass --udid)" >&2; exit 1; }

OUT="${OUT:-${TMPDIR:-/tmp}/capture-$(date +%Y%m%d-%H%M%S)}"
MOV="$OUT.mov"; GRID="$OUT-grid.png"
mkdir -p "$(dirname "$OUT")"

if [ -n "$FROM_MOV" ]; then
  # Re-slice an existing recording: no record, no drive.
  MOV="$FROM_MOV"; DRIVER_END=0
  [ -s "$MOV" ] || { echo "no such recording: $MOV" >&2; exit 1; }
  echo "▶ re-slicing existing $MOV"
else
  rm -f "$MOV" "$GRID"
  echo "▶ recording $UDID -> $MOV"
  xcrun simctl io "$UDID" recordVideo --codec=h264 "$MOV" >/dev/null 2>&1 &
  REC_PID=$!
  # give the recorder a beat to spin up, then mark t0
  sleep 0.6
  T0=$(python3 -c 'import time;print(time.time())')

  if [ -n "$DRIVER" ]; then
    echo "▶ driver: $DRIVER"
    bash -c "$DRIVER" || echo "(driver returned non-zero — continuing to capture)" >&2
  fi
  DRIVER_END=$(python3 -c "import time;print(time.time()-$T0)")
  echo "▶ driver finished at +${DRIVER_END}s; settling ${SETTLE}s"

  sleep "$SETTLE"
  kill -INT "$REC_PID" 2>/dev/null || true
  wait "$REC_PID" 2>/dev/null || true
  [ -s "$MOV" ] || { echo "recording is empty" >&2; exit 1; }
fi

DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$MOV")
echo "▶ recorded ${DUR}s"

# Decide the slice start.
if [ -n "$AT" ]; then
  START="$AT"; echo "▶ slice start (manual): ${START}s"
else
  SEARCH_FROM=$(python3 -c "print(max(0.0, $DRIVER_END + $AFTER))")
  START=$(python3 - "$MOV" "$SEARCH_FROM" "$WINDOW" <<'PY' 2>/dev/null || true
import sys, subprocess, tempfile, glob, os
mov, search_from, window = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
try:
    from PIL import Image, ImageChops
except Exception:
    sys.exit(3)  # signal: no PIL
SR = 10.0  # sample rate for motion analysis
tmp = tempfile.mkdtemp()
subprocess.run(["ffmpeg","-v","error","-ss",str(search_from),"-i",mov,
                "-vf",f"fps={SR},scale=160:-1",os.path.join(tmp,"m_%04d.png")], check=True)
fs = sorted(glob.glob(os.path.join(tmp,"m_*.png")))
if len(fs) < 3: print(f"{search_from:.2f}"); sys.exit(0)
mot=[]
prev=None
for f in fs:
    im=Image.open(f).convert("L")
    if prev is not None:
        d=ImageChops.difference(im,prev); px=d.getdata()
        mot.append(sum(px)/len(px))
    prev=im
# Clip outliers: a screen transition is a single huge spike; clipping at the
# 85th percentile keeps it from outweighing a SUSTAINED animation (the reveal).
if mot:
    cap=sorted(mot)[int(0.85*(len(mot)-1))]
    mot=[min(v,cap) for v in mot]
# sliding window (in samples) with the most integrated motion
w=max(1,int(window*SR))
best_i, best_sum = 0, -1
for i in range(0, max(1, len(mot)-w+1)):
    s=sum(mot[i:i+w])
    if s>best_sum: best_sum, best_i = s, i
# +1 because mot[i] is the diff between frame i and i+1
print(f"{search_from + (best_i)/SR:.2f}")
PY
)
  RC=$?
  if [ -z "${START:-}" ]; then
    START=$(python3 -c "print(max(0.0, $DUR - $WINDOW - 0.2))")
    echo "▶ auto-detect unavailable (no PIL?) — falling back to last ${WINDOW}s: ${START}s"
  else
    echo "▶ slice start (auto, peak motion): ${START}s"
  fi
fi

# Extract + tile into one contact sheet.
FRAMES=$(python3 -c "print(int(round($FPS*$WINDOW)))")
ROWS=$(python3 -c "import math;print(math.ceil($FRAMES/$COLS))")
echo "▶ tiling ${FRAMES} frames @ ${FPS}fps into ${COLS}x${ROWS}"
# -t bounds the slice; tile consumes the frames and emits ONE contact sheet.
ffmpeg -v error -ss "$START" -t "$WINDOW" -i "$MOV" \
  -vf "fps=${FPS},scale=200:-1,tile=${COLS}x${ROWS}:padding=2:color=0x999999" \
  -frames:v 1 -update 1 -y "$GRID"

if [ "$KEEP_FRAMES" = "1" ]; then
  ffmpeg -v error -ss "$START" -i "$MOV" -frames:v "$FRAMES" \
    -vf "fps=${FPS},scale=360:-1" -y "${OUT}-f_%03d.png"
fi

echo
echo "MOV  $MOV"
echo "GRID $GRID"

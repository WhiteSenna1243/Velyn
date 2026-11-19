#!/bin/bash
# Turns a lyric video into pictures Claude can actually look at.
# Claude can't watch video, but it can read images. This makes:
#   <out>/sheet_01.jpg ...   contact sheets (grid of frames, left-to-right, top-to-bottom)
#   <out>/clips/             optional dense frame strips of a short moment (--start/--dur)
#   <out>/INFO.txt           how to read the sheets (timestamps)
#
# Usage:
#   tools/video_to_reference.sh video.mp4                 # overview, 4 frames/sec
#   tools/video_to_reference.sh video.mp4 --fps 6         # denser
#   tools/video_to_reference.sh video.mp4 --start 12 --dur 3 --fps 12   # zoom on 3 s of motion
# Needs ffmpeg:  brew install ffmpeg
set -euo pipefail

if [ $# -lt 1 ]; then sed -n '2,14p' "$0"; exit 1; fi
IN="$1"; shift
FPS=4; START=""; DUR=""; COLS=4; ROWS=4; WIDTH=480
while [ $# -gt 0 ]; do
    case "$1" in
        --fps) FPS="$2"; shift 2;;
        --start) START="$2"; shift 2;;
        --dur) DUR="$2"; shift 2;;
        --cols) COLS="$2"; shift 2;;
        --rows) ROWS="$2"; shift 2;;
        --width) WIDTH="$2"; shift 2;;
        *) echo "unknown option $1"; exit 1;;
    esac
done

command -v ffmpeg >/dev/null || { echo "ffmpeg not found. Install: brew install ffmpeg"; exit 1; }

BASE="$(basename "${IN%.*}")"
OUT="reference/$BASE"
if [ -n "$START" ]; then OUT="$OUT/clip_${START}s"; fi
mkdir -p "$OUT"
rm -f "$OUT"/sheet_*.jpg

SEEK=()
[ -n "$START" ] && SEEK+=(-ss "$START")
[ -n "$DUR" ] && SEEK+=(-t "$DUR")

PER=$((COLS * ROWS))
ffmpeg -v error -y ${SEEK[@]+"${SEEK[@]}"} -i "$IN" \
    -vf "fps=$FPS,scale=$WIDTH:-2,tile=${COLS}x${ROWS}:padding=4:margin=4:color=gray" \
    -q:v 3 "$OUT/sheet_%02d.jpg"

SECS_PER_SHEET=$(python3 -c "print($PER / $FPS)")
cat > "$OUT/INFO.txt" <<INFO
Source: $IN   start: ${START:-0}s   frames per second: $FPS
Each sheet holds $PER frames ($COLS x $ROWS), read left-to-right then top-to-bottom.
Each sheet covers $SECS_PER_SHEET seconds. Sheet N starts at ${START:-0}s + (N-1)*$SECS_PER_SHEET s.
Frame k within a sheet (0-based) is k/$FPS s after the sheet start.
INFO
echo "Wrote $(ls "$OUT"/sheet_*.jpg | wc -l | tr -d ' ') sheet(s) to $OUT"
echo "Next: give Claude the sheets (drag into chat, or in Claude Code: 'look at reference/$BASE/sheet_01.jpg')."

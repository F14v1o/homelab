#!/usr/bin/env bash
# Print video codec and pixel format of every media file under the given paths,
# using the ffprobe that ships inside the Jellyfin container (no ffmpeg on the host needed).
#
# Paths are container paths: /Media and /Media2 as mounted in docker-compose.yml.
#
#   ./codec-scan.sh /Media/Shows /Media2/Shows > /tmp/codecs.txt
#   cut -d'|' -f1 /tmp/codecs.txt | sort | uniq -c | sort -rn     # overview
#   grep -E '^av1|^h264,yuv420p10' /tmp/codecs.txt                 # formats the TV cannot play
#   grep '^unknown' /tmp/codecs.txt                                # broken or unreadable files
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <container path> [...]"; exit 1; }

sudo docker exec jellyfin bash -c '
find "$@" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.webm" \) -print0 \
| sort -z \
| while IFS= read -r -d "" f; do
    r=$(/usr/lib/jellyfin-ffmpeg/ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,pix_fmt -of csv=p=0 "$f" 2>/dev/null)
    echo "${r:-unknown} | $f"
  done
' _ "$@"

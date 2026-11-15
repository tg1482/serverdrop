#!/bin/bash
# Receive Taildrop files from the server into ~/Downloads, log each one to the
# ServerDrop history and post a notification. Runs under launchd
# (io.github.tg1482.serverdrop.recv), so files land even when the app is closed.

TS=/usr/local/bin/tailscale
DEST="$HOME/Downloads"
SUPPORT="$HOME/Library/Application Support/ServerDrop"
LOG="$SUPPORT/history.jsonl"
# shellcheck source=/dev/null
. "$SUPPORT/config"         # SERVER=..., written by install.sh
# --wait prints "waiting for file..." with no newline, so this line does not
# start at "wrote"
WROTE='wrote .* as (/.*) \(([0-9]+) bytes\)$'

mkdir -p "$(dirname "$LOG")"

esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }

while true; do
    out=$("$TS" file get --wait --conflict=rename --verbose "$DEST" 2>&1)
    code=$?
    while IFS= read -r line; do
        [[ $line =~ $WROTE ]] || continue
        path=${BASH_REMATCH[1]}
        bytes=${BASH_REMATCH[2]}
        name=$(basename "$path")
        printf '{"id":"in-%s-%s","at":%s,"dir":"in","name":"%s","bytes":%s,"path":"%s","status":"done","detail":"from %s"}\n' \
            "$(date +%s)" "$RANDOM" "$(date +%s)" "$(esc "$name")" "$bytes" "$(esc "$path")" "$SERVER" >> "$LOG"
        osascript -e 'on run a' \
                  -e 'display notification "Saved to Downloads" with title ("Received " & item 1 of a)' \
                  -e 'end run' "$name" >/dev/null 2>&1
    done <<< "$out"
    if [ $code -ne 0 ]; then
        echo "$(date '+%F %T') tailscale file get failed ($code): $out" >&2
        sleep 10
    fi
done

#!/bin/bash
# Receive Taildrop files into ~/Downloads, add each to the ServerDrop history
# and post a notification. Runs under launchd, so files land while the app is closed.

SUPPORT="$HOME/Library/Application Support/ServerDrop"
. "$SUPPORT/config"         # SERVER=..., written by install.sh
# --wait prints "waiting for file..." with no newline before this
WROTE='wrote .* as (/.*) \([0-9]+ bytes\)$'

esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }

while true; do
    out=$(/usr/local/bin/tailscale file get --wait --conflict=rename --verbose "$HOME/Downloads" 2>&1) \
        || { echo "$(date '+%F %T') $out" >&2; sleep 10; }
    while IFS= read -r line; do
        [[ $line =~ $WROTE ]] || continue
        path=${BASH_REMATCH[1]}
        name=$(basename "$path")
        printf '{"id":"in-%s-%s","at":%s,"dir":"in","name":"%s","path":"%s","status":"done"}\n' \
            "$(date +%s)" "$RANDOM" "$(date +%s)" "$(esc "$name")" "$(esc "$path")" >> "$SUPPORT/history.jsonl"
        osascript -e 'on run a' -e 'display notification "from '"$SERVER"'" with title ("Received " & item 1 of a)' \
                  -e 'end run' "$name" >/dev/null 2>&1
    done <<< "$out"
done

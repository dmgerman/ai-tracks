#!/bin/bash
# Print the timestamp bounding the current recap window for a Claude
# session — the last recap's :CLAUDE-RECAPPED: or, if none, the
# track's :CLAUDE-STARTED:.  Exits non-zero if the track does not
# exist.
#
# Usage:  ai-tracks-recap-since.sh [<session-id>]
# Falls back to $CLAUDE_CODE_SESSION_ID if no arg is given.

set -u

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v emacsclient >/dev/null 2>&1; then
    echo "ai-tracks: emacsclient not found" >&2
    exit 1
fi

session_id="${1:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$session_id" ]; then
    echo "ai-tracks: no session id (arg or CLAUDE_CODE_SESSION_ID)" >&2
    exit 1
fi

out=$(emacsclient -e "(ai-tracks-recap-since \"$session_id\")" 2>&1)
ec=$?
if [ $ec -ne 0 ]; then
    echo "$out" >&2
    exit $ec
fi

# emacsclient prints a string value as "..."; strip the outer quotes.
out="${out#\"}"
out="${out%\"}"
echo "$out"

#!/bin/bash
# Append a Recap heading to the current session's track.
#
# Usage:  ai-tracks-recap.sh [<session-id>]
#         (JSON summary on stdin)
#
# Stdin is expected to be a JSON object with keys:
#   files, decisions, open, next
# each mapping to an array of short strings.  Missing or empty
# sections are dropped by the Emacs side.
#
# Falls back to $CLAUDE_CODE_SESSION_ID if no arg is given.  Blocking
# emacsclient call so we can surface the success timestamp or the
# error message.

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

tmpfile=$(mktemp -t ai-tracks-recap.XXXXXX) || exit 1
mv "$tmpfile" "$tmpfile.json"
tmpfile="$tmpfile.json"

cat > "$tmpfile"

out=$(emacsclient -e "(ai-tracks-recap-add \"$session_id\" \"$tmpfile\")" 2>&1)
ec=$?
if [ $ec -ne 0 ]; then
    echo "$out" >&2
    exit $ec
fi

out="${out#\"}"
out="${out%\"}"
echo "recap added at $out"

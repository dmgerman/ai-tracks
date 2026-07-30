#!/bin/bash
# Append a Close-session POI (the final recap) to the current session's Track.
#
# Usage:  ai-tracks-end-session.sh [<session-id>]
#         (JSON summary on stdin — same schema as ai-tracks-recap.sh)
#
# Same schema and transport as recap: JSON on stdin with keys summary,
# files, decisions, open, next.  Only difference is the resulting POI
# has :POI-CATEGORY: End-session and heading title "Close session ...".

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

tmpfile=$(mktemp -t ai-tracks-end-session.XXXXXX) || exit 1
mv "$tmpfile" "$tmpfile.json"
tmpfile="$tmpfile.json"

cat > "$tmpfile"

out=$(emacsclient -e "(ai-tracks-end-session-add \"$session_id\" \"$tmpfile\")" 2>&1)
ec=$?
if [ $ec -ne 0 ]; then
    echo "$out" >&2
    exit $ec
fi

out="${out#\"}"
out="${out%\"}"
echo "end-session added at $out"

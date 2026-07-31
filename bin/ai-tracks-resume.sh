#!/bin/bash
# Trigger creation of a Resume POI under the current session's Track.
# Same non-blocking pattern as the POI wrapper — Emacs opens the org
# file with point positioned for the user to type their intention.
#
# Usage:  ai-tracks-resume.sh [<session-id>]
# Falls back to $CLAUDE_CODE_SESSION_ID.

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

emacsclient --no-wait -e "(ai-tracks-resume-add \"$session_id\")" \
    >/dev/null 2>&1 &

exit 0

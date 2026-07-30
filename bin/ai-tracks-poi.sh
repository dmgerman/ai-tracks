#!/bin/bash
# Trigger a Point of Interest (POI) under the current session's Track.
# Emacs runs the interaction (category prompt via `completing-read',
# switching to the org file, positioning point), so we fire the call
# non-blocking with `--no-wait' — errors surface in Emacs's minibuffer.
#
# Usage:  ai-tracks-poi.sh [<session-id>]
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

emacsclient --no-wait -e "(ai-tracks-poi-add \"$session_id\")" \
    >/dev/null 2>&1 &

exit 0

#!/bin/bash
# Jump Emacs to this session's Track via org-roam-node-visit.
# Non-blocking — errors surface in Emacs's minibuffer.
#
# Usage:  ai-tracks-goto-track.sh [<session-id>]
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

emacsclient --no-wait -e "(ai-tracks-goto-track \"$session_id\")" \
    >/dev/null 2>&1 &

exit 0

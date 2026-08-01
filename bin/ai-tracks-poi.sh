#!/bin/bash
# Trigger a Point of Interest (POI) under the current session's Track.
# Emacs runs the interaction (category prompt via `completing-read',
# switching to the org file, positioning point), so we fire the call
# non-blocking with `--no-wait' — errors surface in Emacs's minibuffer.
#
# We also locate this session's Claude Code transcript (JSONL) and
# hand its path to Emacs.  Emacs extracts Claude's last answer from
# the transcript, converts it markdown->org via pandoc, and inserts
# it as the POI body.
#
# Usage:  ai-tracks-poi.sh [<session-id> [<transcript-path>]]
# Falls back to $CLAUDE_CODE_SESSION_ID if no session-id given.  If
# no transcript-path given, globs ~/.claude/projects/*/<session-id>.jsonl
# (the session UUID is unique across projects).

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

transcript_path="${2:-}"
if [ -z "$transcript_path" ]; then
    for candidate in "$HOME"/.claude/projects/*/"$session_id".jsonl; do
        if [ -f "$candidate" ]; then
            transcript_path="$candidate"
            break
        fi
    done
fi

if [ -n "$transcript_path" ]; then
    tp_elisp="\"$transcript_path\""
else
    tp_elisp="nil"
fi

# Capture wall-clock time so Emacs can prune JSONL entries that Claude
# writes in response to /at:poi itself (those land in the transcript
# before Emacs reads it).
cutoff_epoch=$(date +%s)

emacsclient --no-wait \
    -e "(ai-tracks-poi-add \"$session_id\" $tp_elisp $cutoff_epoch)" \
    >/dev/null 2>&1 &

exit 0

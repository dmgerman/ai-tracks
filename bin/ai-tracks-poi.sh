#!/bin/bash
# Trigger a Point of Interest (POI) under the current session's Track.
# Emacs runs the interaction (category prompt via `completing-read',
# switching to the org file, positioning point), so we fire the main
# call non-blocking with `--no-wait' — errors surface in Emacs's
# minibuffer.
#
# The optional round pre-check IS blocking so out-of-range errors
# propagate back to Claude Code via a non-zero exit and a stderr
# message; Claude then reports the failure to the user instead of
# silently attaching an empty POI.
#
# We also locate this session's Claude Code transcript (JSONL) and
# hand its path to Emacs.  Emacs extracts the selected exchange from
# the transcript, converts it markdown->org via pandoc, and inserts
# it as the POI body.
#
# Usage:  ai-tracks-poi.sh [<session-id> [<transcript-path> [<round>]]]
# Falls back to $CLAUDE_CODE_SESSION_ID if no session-id given.  If
# no transcript-path given, globs ~/.claude/projects/*/<session-id>.jsonl
# (the session UUID is unique across projects).  Round defaults to 1
# (the most recent exchange).

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

# Round arg: empty -> 1.  Non-numeric or <=0 -> fire an Emacs
# message and exit 1 so Claude sees the rejection.
round_arg="${3:-}"
if [ -z "$round_arg" ]; then
    round=1
else
    if ! [[ "$round_arg" =~ ^[0-9]+$ ]] || [ "$round_arg" -lt 1 ]; then
        # Escape any embedded quotes / backslashes for the elisp string.
        safe=${round_arg//\\/\\\\}
        safe=${safe//\"/\\\"}
        emacsclient --no-wait \
            -e "(message \"ai-tracks: /at:poi round must be a positive integer, got %S\" \"$safe\")" \
            >/dev/null 2>&1 &
        echo "ai-tracks: /at:poi round must be a positive integer, got \"$round_arg\"" >&2
        exit 1
    fi
    round="$round_arg"
fi

# Capture wall-clock time so Emacs can prune JSONL entries that Claude
# writes in response to /at:poi itself (those land in the transcript
# before Emacs reads it).
cutoff_epoch=$(date +%s)

# Blocking pre-check: is round N retrievable?  Runs quickly (JSONL
# walk) and returns a quoted elisp string.
status=$(emacsclient \
    -e "(ai-tracks--poi-round-status $tp_elisp $cutoff_epoch $round)" 2>&1)
if [ "$status" != '"ok"' ]; then
    # Strip surrounding quotes for a cleaner terminal message.
    trimmed="${status#\"}"
    trimmed="${trimmed%\"}"
    echo "ai-tracks: $trimmed" >&2
    exit 1
fi

emacsclient --no-wait \
    -e "(ai-tracks-poi-add \"$session_id\" $tp_elisp $cutoff_epoch $round)" \
    >/dev/null 2>&1 &

exit 0

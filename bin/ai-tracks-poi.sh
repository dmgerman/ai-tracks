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
# Emacs extracts the selected exchange from this session's Claude
# Code transcript (JSONL), converts it markdown->org via pandoc, and
# inserts it as the POI body.  Locating that transcript is Emacs's
# job (`ai-tracks--transcript-path'): the file named after the
# session id stops at the first context compaction, and the live
# leg lives in a differently-named sibling.  We pass a path only
# when the caller supplied one explicitly.
#
# Usage:  ai-tracks-poi.sh [<session-id> [<transcript-path> [<round>]]]
# Falls back to $CLAUDE_CODE_SESSION_ID if no session-id given.
# Round is 0-based and defaults to 0 (the most recent exchange).

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

if [ -n "$transcript_path" ]; then
    tp_elisp="\"$transcript_path\""
else
    tp_elisp="nil"
fi

# Round arg: empty -> 0.  Non-numeric -> fire an Emacs message and
# exit 1 so Claude sees the rejection.  Round is 0-based (N=0 is the
# newest exchange).
round_arg="${3:-}"
if [ -z "$round_arg" ]; then
    round=0
else
    if ! [[ "$round_arg" =~ ^[0-9]+$ ]]; then
        # Escape any embedded quotes / backslashes for the elisp string.
        safe=${round_arg//\\/\\\\}
        safe=${safe//\"/\\\"}
        emacsclient --no-wait \
            -e "(message \"ai-tracks: /at:poi round must be a non-negative integer, got %S\" \"$safe\")" \
            >/dev/null 2>&1 &
        echo "ai-tracks: /at:poi round must be a non-negative integer, got \"$round_arg\"" >&2
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
    -e "(ai-tracks--poi-round-status $tp_elisp $cutoff_epoch $round \"$session_id\")" 2>&1)
if [ "$status" != '"ok"' ]; then
    # Strip surrounding quotes for a cleaner terminal message.
    trimmed="${status#\"}"
    trimmed="${trimmed%\"}"
    echo "ai-tracks: $trimmed" >&2
    exit 1
fi

emacsclient --no-wait \
    -e "(ai-tracks-poi-new $round nil \"$session_id\" $tp_elisp $cutoff_epoch)" \
    >/dev/null 2>&1 &

exit 0

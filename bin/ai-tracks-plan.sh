#!/bin/bash
# Claude Code PostToolUse hook for `ExitPlanMode': record a Plan POI
# under the current session's Track.
#
# Claude Code writes the PostToolUse JSON payload to this script's
# stdin.  We persist it to a temp file and hand the path to Emacs,
# which parses it (session_id, tool_input.plan, tool_response) and
# inserts or overwrites a level-4 Plan POI under the matching Track.
#
# Non-blocking: the recording is passive and the user does not need
# to interact.  Emacs handles missing-Track gracefully by issuing a
# warning; there is no signal to surface back to Claude, so we exit
# 0 unconditionally.

set -u

# Claude may spawn hooks with a minimal PATH; add the usual Homebrew
# locations so `emacsclient' is found on both Apple Silicon and Intel.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v emacsclient >/dev/null 2>&1; then
    exit 0
fi

tmpfile=$(mktemp -t ai-tracks-plan.XXXXXX) || exit 0
mv "$tmpfile" "$tmpfile.json"
tmpfile="$tmpfile.json"

cat > "$tmpfile"

emacsclient --no-wait \
    -e "(ai-tracks-plan-add \"$tmpfile\")" \
    >/dev/null 2>&1 &

exit 0

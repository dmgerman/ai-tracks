#!/bin/bash
# Claude Code PostToolUse hook for `Bash': record a Bead POI under the
# current session's Track whenever the command closed a bead
# (`bd close' / `bd done').
#
# The hook fires on every Bash call, so we filter cheaply here: unless
# the payload mentions a `bd ... close|done' invocation, exit without
# starting emacsclient.  Emacs does the precise parsing of
# tool_input.command, looks each bead up with `bd show --json', and
# only records beads whose status is now `closed'.
#
# Non-blocking: the recording is passive.  Exit 0 unconditionally.

set -u

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

payload=$(cat)

if ! printf '%s' "$payload" | grep -Eq '(^|[^[:alnum:]_-])bd[[:space:]].*(close|done)'; then
    exit 0
fi

if ! command -v emacsclient >/dev/null 2>&1; then
    exit 0
fi

tmpfile=$(mktemp -t ai-tracks-bead.XXXXXX) || exit 0
mv "$tmpfile" "$tmpfile.json"
tmpfile="$tmpfile.json"

printf '%s' "$payload" > "$tmpfile"

emacsclient --no-wait \
    -e "(ai-tracks-bead-add \"$tmpfile\")" \
    >/dev/null 2>&1 &

exit 0

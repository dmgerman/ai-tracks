#!/bin/bash
# Claude Code SessionStart hook: hand the JSON payload to Emacs.
#
# Claude Code writes the SessionStart JSON payload to this script's
# stdin.  We persist it to a temp file and invoke the Emacs handler
# with the file path, so no shell quoting is needed for values like
# `cwd' that may contain metacharacters.
#
# Blocking call: `ai-tracks-session-start' returns either nil (no
# further action needed) or the path to a JSON hook-output file
# containing a `hookSpecificOutput.additionalContext' payload for
# Claude Code to inject as session-start context.  We `cat' the file
# to stdout and delete it.  Emacs returns quickly in every case —
# the Track/POI/capture UI is set up but the function does not wait
# for user interaction.

set -u

# Claude may spawn hooks with a minimal PATH; add the usual Homebrew
# locations so `emacsclient' is found on both Apple Silicon and Intel.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v emacsclient >/dev/null 2>&1; then
    exit 0
fi

tmpfile=$(mktemp -t ai-tracks-session-start.XXXXXX) || exit 0
mv "$tmpfile" "$tmpfile.json"
tmpfile="$tmpfile.json"

cat > "$tmpfile"

result=$(emacsclient -e "(ai-tracks-session-start \"$tmpfile\")" 2>/dev/null)

# Elisp prints nil as literal "nil" and a string with surrounding
# double quotes.  A returned file path is one such quoted string.
if [ -z "$result" ] || [ "$result" = "nil" ]; then
    exit 0
fi

result="${result#\"}"
result="${result%\"}"

if [ -f "$result" ]; then
    cat "$result"
    rm -f "$result"
fi

exit 0

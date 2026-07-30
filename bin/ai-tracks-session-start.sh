#!/bin/bash
# Claude Code SessionStart hook: hand the JSON payload to Emacs.
#
# Claude Code writes the SessionStart JSON payload to this script's
# stdin.  We persist it to a temp file and invoke the Emacs handler
# with the file path, so no shell quoting is needed for values like
# `cwd' that may contain metacharacters.
#
# `--no-wait' plus backgrounding keeps the hook from blocking Claude's
# startup while the user completes the org-capture UI.

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

emacsclient --no-wait -e "(ai-tracks-session-start \"$tmpfile\")" \
    >/dev/null 2>&1 &

exit 0

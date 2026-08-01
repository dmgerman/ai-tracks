# ai-tracks

Records each Claude Code session as POIs under an org-roam node.
Elisp does the work; bash wrappers are thin shims that hand JSON to
Emacs.

## Documentation policy

After any change, evaluate whether `README.md` also needs updating.
`README.md` covers installation, the org layout, and user-visible
slash-command behavior; keep it in sync when those change.

## Vocabulary

- **Track** — a level-3 heading under `** AI Tracks` inside an
  org-roam node. One Track per Claude Code session. Its `:ID:` is
  `claude-<uuid>` (the raw Claude session UUID prefixed with
  `claude-`). Title: `Track [<date>]` — bracketed so org parses it
  as an inactive timestamp (same for all dated POI titles).
- **POI** (Point of Interest) — any level-4 heading under a Track.
  Every POI carries a `:POI-CATEGORY:` property naming its type.
- **POI-CATEGORY values** — closed set:

  | Category | Written by | Trigger |
  |---|---|---|
  | `Recap` | `ai-tracks-recap-add` | `/at:recap` |
  | `Recap` (title `End of session …`) | `ai-tracks-end-session-add` | `/at:end-session` (the final recap of a session; same category, different title only) |
  | `Resume` | `ai-tracks--session-resume-add` | SessionStart hook with `source: resume` |
  | `Commit` | `ai-tracks--insert-commit` | `ai-tracks-magit-mode` fires on any magit commit |
  | `Surprise` \| `Event` \| `Decision` \| `Observation` \| `Other` | `ai-tracks-poi-add` | `/at:poi` (user-authored — "explicit POI" in module vocabulary) |
  | `Summary` | `ai-tracks--append-to-summary` (invoked from `ai-tracks-end-session-add`) | Rolling per-Track summary — the first level-4 child of the Track; gets a new dated bullet group every `/at:end-session`. |

  Explicit values live in `ai-tracks-poi-categories`.

## Resume recovery (missing End-of-session)

If the user closed Claude without running `/at:end-session`, the
previous leg has no wrap-up recap.  On the next `claude -c`, the
SessionStart hook detects this: `ai-tracks--missing-end-of-session-p`
checks whether the bottommost level-4 POI's title starts with
`End of session`.  If not, the hook returns an `additionalContext`
telling Claude to:

1. Run `/at:end-session` first — Claude *has* the previous leg's
   conversation in context via `claude -c`, so it can synthesise the
   summary.  This writes an End-of-session POI whose
   `:CLAUDE-RECAPPED:` becomes the new boundary.
2. Then run `/at:resume` — appends the Resume POI going forward.

The order matters: the Resume POI must be inserted *after* the
End-of-session, or `/at:end-session`'s `ai-tracks-recap-since`
boundary would look at the just-inserted Resume (`CLAUDE-RESUMED`),
find that it is the newest boundary marker, and try to summarise a
zero-length window.

If the last POI *is* an End-of-session (the tidy case), the hook
skips the notification and just appends the Resume POI directly —
no Claude action required.

## Layout inside an org-roam node

Skeleton (see README.md for a filled-out example):

```
* <org-roam node>
** AI Tracks                       (level 2, created on demand)
*** Track [<date>] <intention>     (level 3, :ID: claude-<uuid>)
**** <POI title>                   (level 4, :POI-CATEGORY: <cat>)
***** <sub-section>                (level 5, Recap-shape only:
                                    Files touched, Decisions,
                                    Open threads, Next)
```

Track drawer: `:ID:` (`claude-<uuid>`), `:CLAUDE-CWD:`,
`:CLAUDE-SOURCE:` (`startup | manual`), `:CLAUDE-STARTED:`.

Per-category timestamp drawer key (in addition to `:POI-CATEGORY:`):

- Recap / End-of-session → `:CLAUDE-RECAPPED:`
- Resume → `:CLAUDE-RESUMED:`
- explicit POI → `:CLAUDE-POI:`
- Commit → `:CLAUDE-COMMIT:` plus `:COMMIT-SHA:`, `:COMMIT-AUTHOR:`
- Summary → `:CLAUDE-SUMMARIZED:`

Invariants:

- Summary is always the *first* level-4 child of a Track.
- Recap and End-of-session share `ai-tracks--insert-recap-like`;
  they differ only in title prefix.
- Explicit POI body is `#+begin_quote`(prompt) + Claude's last
  answer (pandoc'd) + user commentary.

## Entry points

### Slash commands (`~/.claude/commands/at/`)

All are namespaced under `at:` to avoid Claude Code's fuzzy-matching
built-ins (a bare `/recap` gets rerouted to the built-in `/recap`).
Custom slash commands are cached at CC session startup — new files
need a fresh session to appear.

| Slash | Emacs function it triggers | Purpose |
|---|---|---|
| `/at:track-start` | `ai-tracks-session-start` | Manually start a Track when the SessionStart hook didn't fire (or was cancelled). Uses `source:"manual"`. |
| `/at:recap` | `ai-tracks-recap-add` | Mid-session recap. Claude gathers boundary + writes the summary JSON. |
| `/at:end-session` | `ai-tracks-end-session-add` | Final wrap-up right before the session ends. Same shape as recap. |
| `/at:resume` | `ai-tracks-resume-add` | Append a Resume POI. Normally auto-fired by the SessionStart hook on `source: resume`; only invoked manually by Claude during the missing-end-of-session recovery flow (see below). |
| `/at:poi` | `ai-tracks-poi-add` | User-typed observation ("explicit POI" in module vocabulary). Emacs prompts for category and puts point in the org file. |

### Automatic triggers

- **Claude Code SessionStart hook** — configured in
  `~/.claude/settings.json`, matcher `startup|resume`. Runs
  `bin/ai-tracks-session-start.sh` which hands the payload to
  `ai-tracks-session-start`. The elisp routes on the `source` field:
  - `startup` opens an `org-roam-node-read` prompt so the user picks
    the parent node and writes an intention.
  - `resume` + existing Track + last POI is an End-of-session →
    appends a Resume POI and drops point in the org file for the
    user to jot down what they intend to do this leg.
  - `resume` + existing Track + missing End-of-session (see
    "Resume recovery" below) → returns a JSON hook-output payload;
    the bash wrapper `cat`s it to stdout so Claude Code injects it
    as `additionalContext`.  No Resume POI is added at this stage.
  - `resume` + missing Track → falls through to the capture UI
    (edge case: the first SessionStart capture was cancelled).
- **`ai-tracks-magit-mode`** (global minor mode, off by default;
  lighter `AITrk`). When on, hooks
  `git-commit-post-finish-hook` (message-editing commits) and
  `magit-post-commit-hook` (`--no-edit` / `--amend --no-edit`). On
  every magit commit it looks up Tracks whose `:CLAUDE-CWD:` is an
  ancestor of the commit's git worktree root and, if any match, pops a
  `completing-read` for the user to attach or skip. Command-line
  commits are deliberately outside this scope. Rebase / cherry-pick
  are auto-skipped (detected via `.git/rebase-*`, `CHERRY_PICK_HEAD`).

## Recurring implementation decisions

- **Transport**: hooks/wrappers write JSON to a temp file and hand
  the *path* to Emacs. No `jq`; no shell-quoting hazards for values
  that may contain quotes, backslashes, or newlines (`cwd`, commit
  body).
- **Blocking**: `--no-wait` for calls whose only success signal is
  the user seeing something in Emacs (SessionStart, `/at:poi`,
  `/at:track-start`). Blocking `emacsclient` for calls that need to
  surface success/failure back to Claude (`/at:recap`, `/at:end-session`,
  boundary lookup).
- **Boundary lookup for recap-like entries**: `ai-tracks-recap-since`
  scans the Track subtree and returns the newest of `:CLAUDE-STARTED:`,
  `:CLAUDE-RECAPPED:`, or `:CLAUDE-RESUMED:`. `/at:end-session` reuses
  the same boundary — an End-of-session summarises the same window a
  Recap would; a `/at:recap` after a Resume summarises only the
  resumed leg.
- **DB, not files, for lookup**: `ai-tracks--commit-candidates` and
  `ai-tracks-recap-since` read from the org-roam DB
  (`org-roam-node-properties` returns the drawer as an alist). No file
  I/O unless we're inserting.
- **Commit → github link**: `ai-tracks--parse-github-remote` matches
  the three usual remote-URL shapes; non-github origins yield no link
  (the URL slot is simply omitted). Full SHA in the URL.
- **`org-roam-gt-mode` dependency**: session capture uses the
  `node+headline` target from `org-roam-gt-capture`. The
  session-start function turns the minor mode on if needed
  (`(unless org-roam-gt-mode (org-roam-gt-mode 1))`).
- **`/at:poi` transcript injection**: the wrapper globs
  `~/.claude/projects/*/<session-id>.jsonl` (session UUID is unique)
  and passes a Unix-epoch cutoff so Emacs can prune newer entries —
  they'd be Claude's own response to `/at:poi`, already flushed to
  the transcript by the time Emacs reads it.  Extraction returns the
  previous user prompt and Claude's last assistant text; both are
  pandoc'd markdown→org, prompt in a `#+begin_quote`, answer as
  body.  `queue-operation` enqueue entries count as genuine user
  turns (mid-turn user submissions never become proper user messages).
- **Raise Emacs**: user-facing entry points call
  `ai-tracks--raise-emacs` before returning so the GUI frame comes
  forward.  Keeps the bash wrappers minimal.

## Files

- `ai-tracks.el` — the module (session capture, recap, POI, end-session,
  commit, magit-mode).
- `bin/ai-tracks-session-start.sh` — SessionStart hook wrapper
  (non-blocking).
- `bin/ai-tracks-recap-since.sh` — prints the boundary for the current
  Track (used by both `/at:recap` and `/at:end-session`).
- `bin/ai-tracks-recap.sh` — reads JSON, appends a Recap POI (blocking).
- `bin/ai-tracks-end-session.sh` — reads JSON, appends an End-of-session
  POI (still `POI-CATEGORY: Recap`; only the title differs) (blocking).
- `bin/ai-tracks-poi.sh` — fires an explicit-POI capture in Emacs
  (non-blocking).
- `bin/ai-tracks-resume.sh` — fires a Resume POI capture in Emacs
  (non-blocking; normally invoked only during recovery from a missing
  End-of-session).
- `~/.claude/commands/at/*.md` — slash-command instructions.
- Loaded via `use-package ai-tracks` in `dmg-ai.org` under
  `** ai-tracks`.

## When adding a new POI type

1. Pick a new `POI-CATEGORY` value.
2. If it's recap-like (summary + optional per-topic sections), call
   `ai-tracks--insert-recap-like` with a new title prefix, timestamp
   drawer key, and category value. Otherwise write a dedicated
   inserter.
3. Add a slash command under `~/.claude/commands/at/` if it's
   user-invoked, and a bash wrapper under `bin/` if it needs a
   transport layer.
4. Update this document.

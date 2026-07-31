# ai-tracks

Records each Claude Code session as structured notes inside an
existing org-roam node, so the conversation and the work it produced
are captured next to the project they belong to.

Everything is written by the Emacs side. Bash wrappers and slash
commands are thin shims that hand JSON to Emacs; the elisp does the
work.

## Vocabulary

- **Track** — a level-3 heading under `** AI Tracks` inside an
  org-roam node. One Track per Claude Code session. Its `:ID:` is
  `claude-<uuid>` (the raw Claude session UUID prefixed with
  `claude-`). Title: `Track <date>`.
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

  The five explicit values live in `ai-tracks-poi-categories`. Recap /
  Resume / Commit / Summary are set by the code that creates the POI.

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

## Recap boundary

A "recap boundary" is the timestamp `ai-tracks-recap-since` returns as
the point in time to summarise *from*. The boundary is the newest of:

- the Track's `:CLAUDE-STARTED:` (initial),
- any POI's `:CLAUDE-RECAPPED:` (Recap and End-of-session), or
- any POI's `:CLAUDE-RESUMED:` (Resume).

Both `/at:recap` and `/at:end-session` use this same boundary — an
end-of-session recap summarises the same window an ordinary Recap
would. Resume creates a boundary so the next `/at:recap` after a
resume only summarises work done in the resumed leg.

## Layout inside an org-roam node

```
* <node title>                                (level 1, org-roam node — user picks at SessionStart)
** AI Tracks                                  (level 2, plain; created on demand)
*** Track 2026-07-30 Thu 06:53 <intention>    (level 3, one per session; :ID: claude-<uuid>)
    :PROPERTIES:
    :ID:            claude-<uuid>
    :CLAUDE-CWD:    /path/session/was/started/in
    :CLAUDE-SOURCE: startup | manual
    :CLAUDE-STARTED: [2026-07-30 Thu 06:53]
    :END:
    <user's stated intention for this session>

**** Recap 2026-07-30 Thu 07:23              (level 4 POI, category Recap)
     :PROPERTIES:
     :POI-CATEGORY:    Recap
     :CLAUDE-RECAPPED: [2026-07-30 Thu 07:23]
     :END:
     - narrative summary bullet
     - narrative summary bullet
***** Files touched   (level 5 sections, all optional)
      - path — one-liner
***** Decisions
      - ...
***** Open threads
      - ...
***** Next
      - ...

**** POI 2026-07-30 Thu 07:34                (level 4, explicit POI)
     :PROPERTIES:
     :POI-CATEGORY: Observation
     :CLAUDE-POI:   [2026-07-30 Thu 07:34]
     :END:
     <user-typed observation>

**** Commit <short> — <subject>               (level 4, magit commit)
     :PROPERTIES:
     :POI-CATEGORY:   Commit
     :CLAUDE-COMMIT:  [YYYY-MM-DD Day HH:MM]
     :COMMIT-SHA:     <full-sha>
     :COMMIT-AUTHOR:  <name>
     :END:

     [[https://github.com/OWNER/REPO/commit/<full-sha>]]     ← only if origin is github; blank line before it

     <full commit body>

     Files:
     - path/a
     - path/b

**** End of session 2026-07-30 Thu 18:00      (level 4, still POI-CATEGORY: Recap)
     :PROPERTIES:
     :POI-CATEGORY:    Recap
     :CLAUDE-RECAPPED: [2026-07-30 Thu 18:00]
     :END:
     - final summary bullet
     - final summary bullet
     (same level-5 sections as Recap)

**** Resume 2026-07-30 Thu 09:15              (level 4, category Resume)
     :PROPERTIES:
     :POI-CATEGORY:   Resume
     :CLAUDE-RESUMED: [2026-07-30 Thu 09:15]
     :END:
     <user-typed reflection on what to accomplish in this resumed leg>
```

The **Summary** node (POI-CATEGORY: Summary) is a rolling per-Track
digest that lives as the *first* level-4 child of the Track — inserted
by `ai-tracks--append-to-summary` on demand from
`ai-tracks-end-session-add`.  Each `/at:end-session` appends the
`summary` array from the payload as a new dated bullet group and
updates `:CLAUDE-SUMMARIZED:` to the current timestamp:

```
**** Summary
     :PROPERTIES:
     :POI-CATEGORY:      Summary
     :CLAUDE-SUMMARIZED: [2026-07-31 Fri 09:15]   ← newest group's timestamp
     :END:

     [2026-07-30 Thu 09:04]:
     - accomplished 1
     - accomplished 2

     [2026-07-31 Fri 09:15]:
     - accomplished 3
     - accomplished 4
```

Recaps and End-of-session share code (`ai-tracks--insert-recap-like`);
they only differ in title prefix. Explicit POIs, Resumes, and Commits
each have their own writer.

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

# ai-tracks

Record each Claude Code session as structured notes inside an
existing org-roam node. The conversation, its recaps, its POIs, and
the commits it produces all land under a single `Track` heading next
to the project they belong to.

## Requirements

- Emacs 28.1 or later.
- [`org-roam`](https://github.com/org-roam/org-roam) 2.2.2+.
- [`org-roam-gt`](https://github.com/dmgerman/org-roam-gt) 0.4+
  (provides the `node+headline` capture target).
- Claude Code (for the SessionStart hook and slash commands).
- `magit` (optional — for the commit-tracking minor mode).
- `pandoc` (optional — used by `/at:poi` to convert Claude's last
  answer from markdown to org; without it, the raw markdown is
  inserted and a warning is shown in the minibuffer).

## Installation

Clone the module into `~/.emacs.d/modules/ai-tracks/` and load it with
`use-package`:

```emacs-lisp
(use-package ai-tracks
  :straight nil
  :load-path "~/.emacs.d/modules/ai-tracks"
  :after (org-roam org-roam-gt)
  :commands (ai-tracks-session-start
             ai-tracks-recap-since
             ai-tracks-recap-add
             ai-tracks-poi-new
             ai-tracks-resume-add
             ai-tracks-magit-mode))
```

## Configuring Claude Code

### `~/.claude/settings.json`

Three things need to go into your Claude Code settings: the
SessionStart hook (fires on both `startup` and `resume`), the
PostToolUse hook for `ExitPlanMode` (records a Plan POI every time
you approve, reject, or edit a plan), and a permission entry so
Claude can invoke the ai-tracks scripts without prompting each time.

Full block, copy-paste ready — **replace `/Users/YOU` with your home
directory**:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/YOU/.emacs.d/modules/ai-tracks/bin/ai-tracks-session-start.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "ExitPlanMode",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/YOU/.emacs.d/modules/ai-tracks/bin/ai-tracks-plan.sh"
          }
        ]
      }
    ]
  },
  "permissions": {
    "allow": [
      "Bash(/Users/YOU/.emacs.d/modules/ai-tracks/bin/ai-tracks-recap-since.sh *)",
      "Bash(/Users/YOU/.emacs.d/modules/ai-tracks/bin/ai-tracks-recap.sh *)",
      "Bash(/Users/YOU/.emacs.d/modules/ai-tracks/bin/ai-tracks-end-session.sh *)",
      "Bash(/Users/YOU/.emacs.d/modules/ai-tracks/bin/ai-tracks-poi.sh *)",
      "Bash(/Users/YOU/.emacs.d/modules/ai-tracks/bin/ai-tracks-resume.sh *)",
      "Bash(/Users/YOU/.emacs.d/modules/ai-tracks/bin/ai-tracks-goto-track.sh *)",
      "Bash(/Users/YOU/.emacs.d/modules/ai-tracks/bin/ai-tracks-plan.sh *)"
    ]
  }
}
```

**If `~/.claude/settings.json` doesn't exist**, save the block above
as your entire file (with the path substitution done).

**If it exists**, merge the two top-level keys (`hooks` and
`permissions`) into your file — don't overwrite the whole thing.
If you already have `hooks.SessionStart` or `permissions.allow`
entries, append rather than replace: both are arrays.

Notes:

- Permission entries must use the **literal absolute path** — Claude
  Code does not expand `~` or `$HOME` when matching permission rules.
  The syntax `Bash(<path> *)` (space before `*`) matches the script
  invoked with any arguments.
- The hook `command` string is executed via the shell, so `$HOME`
  would expand there — but keeping literal paths in both places is
  simpler.
- The `permissions.allow` block is not strictly required — without
  it, Claude Code will just prompt on first use of each script.
  Adding it saves you the confirmations.

### Slash commands (`~/.claude/commands/at/`)

`/at:track-start`, `/at:recap`, `/at:end-session`, `/at:poi`, and
`/at:resume` live in `~/.claude/commands/at/*.md`. Copy the `.md`
files from this repo's `.claude/commands/at/` there (or symlink the
directory).

Claude Code caches its slash-command list at session start, so
newly-added commands only show up in a fresh session (`/exit` and
relaunch).

## Enabling commit tracking

Optional. When on, each magit commit prompts you in Emacs to attach
the commit to a Track:

```emacs-lisp
;; Enable manually:
(ai-tracks-magit-mode 1)
```

Or add `(ai-tracks-magit-mode 1)` to your Emacs init after ai-tracks
loads. Command-line commits are deliberately outside this scope.

## Concepts

- **Track** — one heading per Claude session, `:ID: claude-<uuid>`,
  living under a `** AI Tracks` heading you pick at session start.
- **POI** (Point of Interest) — any level-4 heading under a Track.
  Every POI carries a `:POI-CATEGORY:` naming its kind.

Categories:

| Category | How it's created |
|---|---|
| `Recap` | `/at:recap` (mid-session) or `/at:end-session` (final wrap-up, title `End of session …`) |
| `Resume` | Auto: SessionStart hook fires with `source: resume` |
| `Commit` | Auto: `ai-tracks-magit-mode` on a magit commit |
| `Plan` | Auto: PostToolUse hook on `ExitPlanMode`. The POI is created every time Claude submits a plan for approval. Rule: if the trailing Plan POI is `rejected`, the incoming fire is a *revision* — it overwrites in place, bumping `:PLAN-REVISIONS:` (carries `:PLAN-FIRST-SUBMITTED:` across revisions and records the prior status in `:PLAN-PREVIOUS-STATUS:`). If the trailing Plan is `accepted` or `edited`, the incoming fire is a *new plan* — it appends a fresh POI and stamps `:PLAN-FINISHED-AT:` on the prior one. `/at:end-session` stamps `:PLAN-FINISHED-AT:` on the most recent Plan POI. Absence of `:PLAN-FINISHED-AT:` means "still in flight". `:POI-SUB-CATEGORY:` records `accepted` / `rejected` / `edited`. Title is the plan's own first `#` heading prefixed with `Plan [<date>]` (fallback `Plan [<date>]` when the plan carries no heading). |
| `Surprise` \| `Event` \| `Decision` \| `Observation` \| `Other` | `/at:poi` (you pick from the list) |
| `Summary` | Auto on every `/at:end-session` — appended to a rolling Summary heading at the top of the Track |

## Slash commands

| Command | What it does |
|---|---|
| `/at:track-start` | Manually create a Track for the current session (if the SessionStart hook didn't fire or you cancelled it). |
| `/at:recap` | Ask Claude to summarise work since the last boundary and append a Recap POI. |
| `/at:end-session` | Final wrap-up: appends an `End of session …` POI and grows the rolling Summary node. Run this before you close Claude. |
| `/at:poi [N]` | Opens an interactive POI capture in Emacs — pick a category. The previous user prompt and Claude's last answer are pulled verbatim from the session's JSONL transcript, converted markdown→org via pandoc, and inserted as the POI body; point lands on a blank line below for your own commentary. Optional 0-based `N` picks a farther-back exchange (default 0 = most recent, 1 = the one before, and so on). Requires `pandoc` on `PATH` for the conversion (raw markdown is inserted with a minibuffer warning if pandoc is missing). |
| `/at:resume` | Append a Resume POI. Normally auto-fired on resume; only invoked manually during the missing-end-of-session recovery flow. |
| `/at:goto-track` | Jump Emacs to this session's Track (uses org-roam node navigation). |

Every wrapper raises the Emacs GUI frame to the foreground when it
finishes, so if you're focused on the terminal when a command runs,
Emacs comes forward to show you the resulting POI or capture prompt.

## Adding a POI directly from Emacs

`M-x ai-tracks-poi-new` invokes the same function `/at:poi` does,
just without going through Claude.  Emacs first shows a
`completing-read` picker of the newest exchanges — each row is
`[N] <first line of prompt, truncated>` — with a default entry
`(no exchange — empty POI)` so `RET` records a POI with just the
heading and drawer (no body).  Pick an exchange to embed it as
the body (user prompt in a `#+begin_quote`, Claude's answer
following, both pandoc-converted markdown→org); point lands on a
blank line below so you can add your own commentary.  After the
exchange choice Emacs prompts for the category.

The picker's depth and preview width are controlled by
`ai-tracks-poi-picker-limit` (default 30) and
`ai-tracks-poi-picker-width` (default 100 chars).

Must be invoked from inside a Track subtree so the session UUID
can be derived from the enclosing Track's `:ID:`.  Signals a
`user-error` — inserting nothing — when point is not inside a
Track or no transcript file exists for this session.

## Typical workflow

1. **Start Claude Code** in your project directory. The SessionStart
   hook fires: Emacs opens an `org-roam-node-read` prompt for you to
   pick the parent node for this session's Track. Type an intention
   (what you're going to work on) and `C-c C-c` to finish.
2. **Work with Claude.** As you go:
   - Run `/at:poi` any time you want to mark an observation
     (surprise, event, decision, etc.).
   - Run `/at:recap` periodically to snapshot progress; Claude writes
     a Recap POI with summary, files touched, decisions, open
     threads, and next steps.
   - Commit through magit while `ai-tracks-magit-mode` is on to have
     each commit prompted for attachment to the Track.
3. **Before closing Claude**, run `/at:end-session`. Claude writes a
   final `End of session …` POI *and* appends its bullets as a new
   dated group to the Track's rolling `Summary` heading.
4. **Resume with `claude -c`** later. The SessionStart hook fires:
   - If the last leg was properly closed with an End-of-session, a
     `Resume` POI is appended and Emacs drops point in the org file
     so you can jot down what you're planning to accomplish this leg.
   - If you forgot to run `/at:end-session`, the hook injects a
     notice into the resumed session asking Claude to run
     `/at:end-session` first (Claude has the previous leg's
     conversation in context) and then `/at:resume`. Your history
     stays complete.

## What the org file looks like

Dates in POI titles are wrapped in `[]` so org-mode parses them as
inactive timestamps (they show up in agenda date searches, sparse
trees, etc.).

```
* <your node title>                            (level 1, org-roam node)
** AI Tracks                                   (level 2, plain)
*** Track [2026-07-30 Thu 06:53] <intention>   (level 3, :ID: claude-<uuid>)

**** Summary                                   (rolling per-Track)
     :PROPERTIES:
     :POI-CATEGORY:      Summary
     :CLAUDE-SUMMARIZED: [2026-07-31 Fri 09:15]
     :END:

     [2026-07-30 Thu 09:04]:
     - accomplished 1
     - accomplished 2

     [2026-07-31 Fri 09:15]:
     - accomplished 3

**** Recap [2026-07-30 Thu 07:23]              (mid-session recap)
     - narrative summary bullets
***** Files touched
***** Decisions
***** Open threads
***** Next

**** POI [2026-07-30 Thu 07:34]                (explicit observation)
     :PROPERTIES:
     :POI-CATEGORY: Observation
     :END:

     #+begin_quote
     <the previous user prompt, from the JSONL transcript>
     #+end_quote

     <Claude's last answer, pandoc'd markdown→org>

     <your typed note>

**** Commit abc123 — Fix parser bug            (from magit)
     [[https://github.com/OWNER/REPO/commit/<sha>]]

     <full commit body>
     Files:
     - path/a
     - path/b

**** Plan [2026-07-30 Thu 08:12] Refactor the parser   (title = timestamp + first `#`)
     :PROPERTIES:
     :POI-CATEGORY:         Plan
     :POI-SUB-CATEGORY:     accepted
     :PLAN-REVISIONS:       2
     :PLAN-FIRST-SUBMITTED: [2026-07-30 Thu 08:03]
     :PLAN-PREVIOUS-STATUS: rejected
     :PLAN-FINISHED-AT:     [2026-07-30 Thu 08:47]   (stamped when the next plan started or end-of-session ran)
     :CLAUDE-PLANNED:       [2026-07-30 Thu 08:12]
     :END:

     <plan body, pandoc'd markdown→org, headings demoted to level 5+>

**** End of session [2026-07-30 Thu 09:04]     (final recap of the leg)

**** Resume [2026-07-31 Fri 08:00]             (start of a new leg)
     <your typed intention for this resumed leg>
```

## Manual usage (without a Claude session)

Each slash command has a small bash wrapper you can invoke directly
if you want to test or script it. See `bin/`:

- `ai-tracks-session-start.sh` — takes SessionStart-shape JSON on
  stdin (`{session_id, cwd, source}`) and calls the emacs handler.
- `ai-tracks-recap.sh`, `ai-tracks-end-session.sh` — take the summary
  JSON on stdin (`{summary, files, decisions, open, next}`) and the
  session id as `$1` (defaults to `$CLAUDE_CODE_SESSION_ID`).
- `ai-tracks-recap-since.sh` — prints the boundary timestamp for
  the given session.
- `ai-tracks-poi.sh`, `ai-tracks-resume.sh`, `ai-tracks-goto-track.sh`
  — fire an interactive capture / navigation in Emacs; no stdin,
  session id as `$1`.
- `ai-tracks-plan.sh` — takes PostToolUse-shape JSON for the
  `ExitPlanMode` tool on stdin (`{session_id, tool_response:
  {content: "...Your plan has been saved to: <path>..."}}`) and
  calls `ai-tracks-plan-add`.  The plan itself is not in the
  payload — Emacs reads it from disk at the path extracted from
  `tool_response.content`.

## Troubleshooting

**Nothing happens when I commit.** `ai-tracks-magit-mode` is off by
default; enable it with `M-x ai-tracks-magit-mode`. Check the
modeline for the `AITrk` lighter.

**Slash commands aren't recognised.** Claude Code caches its
custom-command list at session start. Quit and relaunch Claude Code
after adding new commands. Custom commands must live in
`~/.claude/commands/at/*.md` (the `at:` prefix is the folder name).

**Emacs error on `/at:recap` / `/at:end-session`: "no track with ID
claude-<uuid>; run /track-start first."** The SessionStart capture
was cancelled or the file was moved. Run `/at:track-start` to create
the Track manually, then retry.

**Track candidates for a commit include an old test entry.** Delete
the stale Track heading from its org file; org-roam re-sync (or the
next `org-roam-db-sync`) drops it from the DB and the picker.

## Files

- `ai-tracks.el` — the module.
- `bin/*.sh` — bash wrappers for the slash commands and the
  SessionStart hook.
- `README.md` — this file.
- `CLAUDE.md` — implementation notes for agents editing this module.

## License

GPL-3.0-or-later. See the file header of `ai-tracks.el`.

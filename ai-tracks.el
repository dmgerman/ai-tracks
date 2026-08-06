;;; ai-tracks.el --- Record AI coding sessions as org-roam entries  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: outlines, hypermedia, tools
;; Package-Requires: ((emacs "28.1") (org-roam "2.2.2") (org-roam-gt "0.4"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Bridges Claude Code hooks to org-roam so each Claude session is
;; recorded as an "AI track" under an org-roam node the user picks.
;;
;; The Claude Code SessionStart hook runs a shell wrapper that dumps
;; the hook's JSON payload to a temp file and hands the path to
;; `ai-tracks-session-start' via `emacsclient --no-wait'.  The parsing
;; happens here so the wrapper stays trivial and there is no jq or
;; shell-quoting dependency.
;;
;; Layout produced inside the chosen node:
;;
;;   * <node title>                       (level 1, org-roam node)
;;   ** AI Tracks                         (level 2, plain, created if missing)
;;   *** Track 2026-07-30 Thu 14:32       (level 3, one per session)
;;       :PROPERTIES:
;;       :ID: claude-<uuid>
;;       :CLAUDE-CWD: ...
;;       :CLAUDE-SOURCE: startup
;;       :CLAUDE-STARTED: [2026-07-30 Thu 14:32]
;;       :END:
;;       <user's intention for the session>

;;; Code:

(require 'json)
(require 'org-roam)
(require 'org-roam-capture)
(require 'org-roam-gt-capture)

(defun ai-tracks--escape-capture (str)
  "Escape STR so `%' characters are safe inside an `org-capture' template.
`org-capture' interprets `%' as the start of an expansion directive;
doubling any `%' present in an interpolated value keeps it literal."
  (replace-regexp-in-string "%" "%%" (or str "")))

(defun ai-tracks--cwd-as-link (path)
  "Wrap PATH as an org `file:' link.
Property values that look like `/word/' are otherwise matched as
italic by org's emphasis parser and (with `org-hide-emphasis-markers'
on) display with the delimiter slashes hidden.  Wrapping the path in
`[[file:...]]' keeps the value clickable and defeats emphasis parsing.
Returns nil when PATH is nil."
  (when path (format "[[file:%s]]" path)))

(defun ai-tracks--unwrap-cwd (value)
  "Return the plain path from a :CLAUDE-CWD: property VALUE.
Accepts both the current `[[file:/path]]' link form and legacy raw
paths so older Tracks continue to resolve.  Returns nil for nil."
  (when value
    (if (string-match "\\`\\[\\[file:\\(.*\\)\\]\\]\\'" value)
        (match-string 1 value)
      value)))

(declare-function ns-do-applescript "nsfns.m")

(defun ai-tracks--raise-emacs ()
  "Bring the current Emacs frame to the foreground and give it focus.
Called from user-facing entry points so wrappers stay minimal.
On macOS, activates Emacs.app first via AppleScript so the frame
comes to the front even when another app has focus."
  (when (eq system-type 'darwin)
    (ns-do-applescript "tell application \"Emacs\" to activate"))
  (select-frame-set-input-focus (selected-frame)))

(defun ai-tracks--capture-session (session-id cwd source)
  "Trigger the org-roam capture for a new AI track.
SESSION-ID is the Claude Code session UUID.  CWD and SOURCE come from
the SessionStart JSON payload; either may be nil."
  (unless (bound-and-true-p org-roam-gt-mode)
    (org-roam-gt-mode 1))
  (let* ((now       (current-time))
         (title     (format-time-string "Track [%Y-%m-%d %a %H:%M]" now))
         (started   (format-time-string "[%Y-%m-%d %a %H:%M]" now))
         (id        (format "claude-%s" session-id))
         (body      (format
                     (concat
                      "*** %s\n"
                      ":PROPERTIES:\n"
                      ":ID:       %s\n"
                      ":CLAUDE-CWD: %s\n"
                      ":CLAUDE-SOURCE: %s\n"
                      ":CLAUDE-STARTED: %s\n"
                      ":END:\n"
                      "%%?")
                     (ai-tracks--escape-capture title)
                     (ai-tracks--escape-capture id)
                     (ai-tracks--escape-capture (ai-tracks--cwd-as-link cwd))
                     (ai-tracks--escape-capture source)
                     (ai-tracks--escape-capture started)))
         (org-roam-capture-templates
          `(("t" "AI Track"
             entry ,body
             :target (node+headline nil "AI Tracks")
             :empty-lines 1))))
    (ai-tracks--raise-emacs)
    (org-roam-capture-)))

;;;###autoload
(defun ai-tracks-resume-add (session-id)
  "Insert a level-4 Resume POI under the Track for SESSION-ID.
Positions point after the drawer so the user can type a reflection on
what they intend to accomplish in this resumed session.  Saves the
buffer immediately."
  (let* ((marker (ai-tracks--track-marker session-id))
         (now   (current-time))
         (title (format-time-string "Resume [%Y-%m-%d %a %H:%M]" now))
         (ts    (format-time-string "[%Y-%m-%d %a %H:%M]" now)))
    (switch-to-buffer (marker-buffer marker))
    (goto-char (marker-position marker))
    (goto-char (save-excursion (org-end-of-subtree t t)))
    (unless (bolp) (insert "\n"))
    (insert (format "**** %s\n:PROPERTIES:\n:POI-CATEGORY: Resume\n:CLAUDE-RESUMED: %s\n:END:\n"
                    title ts))
    (org-reveal)
    (save-buffer)
    (ai-tracks--raise-emacs)
    ts))

(defun ai-tracks--last-poi-title (session-id)
  "Return the title of the bottommost level-4 POI under the Track for SESSION-ID, or nil."
  (let ((marker (ai-tracks--track-marker session-id)))
    (org-with-point-at marker
      (save-restriction
        (org-narrow-to-subtree)
        (goto-char (point-max))
        (when (re-search-backward "^\\*\\{4\\} " nil t)
          (substring-no-properties (org-get-heading t t t t)))))))

(defun ai-tracks--missing-end-of-session-p (session-id)
  "Non-nil if the Track has POIs and the last one is not an End-of-session.
Signals that the previous leg was never wrapped up before Claude closed."
  (let ((title (ai-tracks--last-poi-title session-id)))
    (and title (not (string-prefix-p "End of session" title)))))

(defconst ai-tracks--resume-recovery-message
  (concat
   "IMPORTANT — ai-tracks session-continuity task.  The previous leg of this Claude session "
   "was never closed with an End-of-session recap.  Before addressing any user request:\n\n"
   "1. Run /at:end-session to summarise the previous leg's work "
   "(you have that leg's conversation in context via `claude -c`).\n"
   "2. Run /at:resume to record this resume event as a Resume POI.\n\n"
   "Then proceed with the user's request.")
  "Message injected into the resumed Claude session when the previous leg
was not wrapped up with an End-of-session recap.  Instructs Claude to
run the two slash commands in order so the boundary lookup stays
consistent (End-of-session first — its :CLAUDE-RECAPPED: becomes the
boundary — then /at:resume adds the Resume POI going forward).")

(defun ai-tracks--write-hook-notify (context-string)
  "Write CONTEXT-STRING as a SessionStart hookSpecificOutput JSON blob to a temp file.
Returns the path.  The bash wrapper reads and prints this file, then deletes it."
  (let ((out-file (make-temp-file "ai-tracks-notify-" nil ".json"))
        (payload `((hookSpecificOutput
                    . ((hookEventName . "SessionStart")
                       (additionalContext . ,context-string))))))
    (with-temp-file out-file
      (insert (json-encode payload)))
    out-file))

;;;###autoload
(defun ai-tracks-session-start (json-file)
  "Handler for the Claude Code SessionStart hook (startup and resume).
JSON-FILE is a path to the payload the hook wrote to disk; it is read
and deleted.

Routes on the `source' field:

  startup                                    open the org-roam capture UI
                                             (new Track).
  resume + Track + End-of-session present    append a Resume POI.
  resume + Track + End-of-session missing    return a notify-file path
                                             so bash can inject a
                                             context message asking
                                             Claude to run
                                             /at:end-session then
                                             /at:resume (do NOT add
                                             the Resume POI here —
                                             /at:end-session's
                                             boundary lookup must not
                                             see the resume yet).
  resume + no Track                          fall through to the
                                             capture UI (edge case:
                                             the first SessionStart
                                             capture was cancelled).

Return value: path to a JSON hook-output file, or nil."
  (interactive "fClaude Code SessionStart JSON file: ")
  (let ((payload
         (unwind-protect
             (with-temp-buffer
               (insert-file-contents json-file)
               (json-parse-buffer :object-type 'alist :null-object nil))
           (ignore-errors (delete-file json-file)))))
    (let ((session-id (alist-get 'session_id payload))
          (cwd        (alist-get 'cwd payload))
          (source     (alist-get 'source payload)))
      (unless (stringp session-id)
        (user-error "ai-tracks: no session_id in payload"))
      (cond
       ((and (equal source "resume")
             (org-id-find (format "claude-%s" session-id) 'marker))
        (if (ai-tracks--missing-end-of-session-p session-id)
            (ai-tracks--write-hook-notify ai-tracks--resume-recovery-message)
          (ai-tracks-resume-add session-id)
          nil))
       (t
        (ai-tracks--capture-session session-id cwd source)
        nil)))))

;;;; Recap

(defun ai-tracks--track-marker (session-id)
  "Return a marker at the track heading for SESSION-ID, or signal a user-error.
Session-id is the raw Claude Code UUID; the heading's :ID: is
\"claude-<uuid>\"."
  (let* ((track-id (format "claude-%s" session-id))
         (marker (org-id-find track-id 'marker)))
    (unless marker
      (user-error "ai-tracks: no track with ID %s; run /track-start first" track-id))
    marker))

(defun ai-tracks-recap-since (session-id)
  "Return the timestamp bounding the current recap window for SESSION-ID.
Boundary events are the newest of:
  - the Track's :CLAUDE-STARTED: (initial boundary),
  - each POI's :CLAUDE-RECAPPED: (Recap and End-of-session), and
  - each POI's :CLAUDE-RESUMED: (Resume).
Signals a user-error if none is found."
  (let ((marker (ai-tracks--track-marker session-id))
        (latest nil))
    (org-with-point-at marker
      (org-map-entries
       (lambda ()
         (dolist (key '("CLAUDE-STARTED" "CLAUDE-RECAPPED" "CLAUDE-RESUMED"))
           (when-let* ((ts (org-entry-get (point) key)))
             (when (or (not latest) (string> ts latest))
               (setq latest ts)))))
       nil 'tree))
    (or latest
        (user-error "ai-tracks: no boundary timestamp on Track for %s"
                    session-id))))

(defun ai-tracks--recap-format-section (heading items)
  "Return a string for one level-5 recap section with HEADING and ITEMS.
Empty when ITEMS is nil or empty."
  (if (and items (listp items) (> (length items) 0))
      (concat (format "***** %s\n" heading)
              (mapconcat (lambda (item) (format "- %s\n" item)) items ""))
    ""))

(defun ai-tracks--read-payload (json-file)
  "Read JSON-FILE, delete it, and return the parsed alist.
Arrays are decoded as lists.  Both JSON null and JSON false decode
to elisp nil so `alist-get' returns falsy values for both — without
this, `false' decodes to the symbol `:false' which is truthy in
elisp and silently miscategorises booleans in downstream code."
  (unwind-protect
      (with-temp-buffer
        (insert-file-contents json-file)
        (json-parse-buffer
         :object-type 'alist
         :array-type 'list
         :null-object nil
         :false-object nil))
    (ignore-errors (delete-file json-file))))

(defun ai-tracks--insert-recap-like (session-id payload title-prefix property-key category)
  "Append a level-4 POI heading of a recap-like variant under SESSION-ID's Track.
PAYLOAD is a parsed alist (see `ai-tracks--read-payload') with keys
summary, files, decisions, open, next — each an array of short strings.
TITLE-PREFIX prefixes the timestamp in the heading title (e.g. \"Recap\",
\"End of session\").  PROPERTY-KEY is the drawer key holding the entry's
timestamp (e.g. \"CLAUDE-RECAPPED\").  CATEGORY is the :POI-CATEGORY:
value.

Switches to the Track's buffer and lands point on the inserted
heading's title line so the user sees the fresh POI when the
top-level caller raises Emacs.  Does not raise on its own — that
is the caller's responsibility, so end-session (which does further
work after this returns) can raise once at the end."
  (let* ((marker (ai-tracks--track-marker session-id))
         (now   (current-time))
         (title (format-time-string
                 (concat title-prefix " [%Y-%m-%d %a %H:%M]") now))
         (ts    (format-time-string "[%Y-%m-%d %a %H:%M]" now))
         (sections '((files     . "Files touched")
                     (decisions . "Decisions")
                     (open      . "Open threads")
                     (next      . "Next")))
         heading-pos)
    (switch-to-buffer (marker-buffer marker))
    (goto-char (marker-position marker))
    (goto-char (save-excursion (org-end-of-subtree t t)))
    (unless (bolp) (insert "\n"))
    (setq heading-pos (point))
    (insert (format "**** %s\n:PROPERTIES:\n:POI-CATEGORY: %s\n:%s: %s\n:END:\n"
                    title category property-key ts))
    ;; Summary bullets are the heading's own body text: a narrative
    ;; list of what was accomplished, above the per-topic level-5
    ;; sections below.
    (let ((summary (alist-get 'summary payload)))
      (when (and summary (listp summary) (> (length summary) 0))
        (dolist (item summary)
          (insert (format "- %s\n" item)))))
    (dolist (section sections)
      (insert (ai-tracks--recap-format-section
               (cdr section)
               (alist-get (car section) payload))))
    (save-buffer)
    (goto-char heading-pos)
    (org-reveal)
    ts))

(defun ai-tracks--find-or-create-summary-node (track-marker)
  "Return a marker at the Summary heading under the Track at TRACK-MARKER.
Creates a level-4 `Summary' heading as the first child of the Track
if it doesn't already exist.  The new heading carries
:POI-CATEGORY: Summary and an initially-blank :CLAUDE-SUMMARIZED:.
The heading title format is `Summary [<date>]' where the date is
the time the Summary node was created; the drawer's
:CLAUDE-SUMMARIZED: is refreshed on every append.  The lookup
regex accepts both the current `Summary [...]' form and the
legacy bare `Summary' from older Tracks."
  (org-with-point-at track-marker
    (save-restriction
      (org-narrow-to-subtree)
      (goto-char (point-min))
      (let ((existing (save-excursion
                        (when (re-search-forward
                               "^\\*\\{4\\} Summary\\(?: \\[.*\\]\\)?$" nil t)
                          (line-beginning-position)))))
        (if existing
            (progn (goto-char existing) (point-marker))
          ;; Insert as first level-4 child (or at end if no children).
          (let ((insert-at (save-excursion
                             (goto-char (point-min))
                             (if (re-search-forward "^\\*\\{4\\} " nil t)
                                 (line-beginning-position)
                               (point-max)))))
            (goto-char insert-at)
            (unless (bolp) (insert "\n"))
            (let ((heading-start (point))
                  (ts (format-time-string "[%Y-%m-%d %a %H:%M]" (current-time))))
              (insert (format "**** Summary %s\n" ts)
                      ":PROPERTIES:\n"
                      ":POI-CATEGORY: Summary\n"
                      ":CLAUDE-SUMMARIZED: \n"
                      ":END:\n")
              (goto-char heading-start)
              (point-marker))))))))

(defun ai-tracks--append-to-summary (session-id items)
  "Append ITEMS (list of strings) as a new dated bullet list under Summary.
Finds or creates the Summary node for SESSION-ID's Track, appends a
new group headed by the current timestamp with one bullet per item,
and updates :CLAUDE-SUMMARIZED: on the Summary drawer.
No-op when ITEMS is nil or empty."
  (when (and items (listp items) (> (length items) 0))
    (let* ((track-marker   (ai-tracks--track-marker session-id))
           (summary-marker (ai-tracks--find-or-create-summary-node track-marker))
           (now (current-time))
           (ts  (format-time-string "[%Y-%m-%d %a %H:%M]" now)))
      (org-with-point-at summary-marker
        (org-entry-put nil "CLAUDE-SUMMARIZED" ts)
        (goto-char (save-excursion (org-end-of-subtree t t)))
        (unless (bolp) (insert "\n"))
        (insert "\n" (format "%s:\n" ts))
        (dolist (item items)
          (insert (format "- %s\n" item)))
        (save-buffer)))))

(defun ai-tracks-recap-add (session-id json-file)
  "Append a Recap POI under the Track for SESSION-ID.
See `ai-tracks--insert-recap-like' for the JSON schema."
  (prog1
      (ai-tracks--insert-recap-like
       session-id (ai-tracks--read-payload json-file)
       "Recap" "CLAUDE-RECAPPED" "Recap")
    (ai-tracks--raise-emacs)))

(defun ai-tracks-end-session-add (session-id json-file)
  "Append an End-of-session POI and update the Track's rolling Summary.
The End-of-session POI is semantically a Recap (same category and
drawer key) with a different title.  Additionally, the `summary'
bullets are appended as a new dated group to the Track's Summary
node (created as the first level-4 child on demand), and the most
recent Plan POI (if any) gets `:PLAN-FINISHED-AT:' stamped so
outstanding plans are recorded as done at the wrap-up moment.
Same JSON schema as `ai-tracks-recap-add'."
  (let* ((payload (ai-tracks--read-payload json-file))
         (ts (ai-tracks--insert-recap-like
              session-id payload
              "End of session" "CLAUDE-RECAPPED" "Recap"))
         (marker (ai-tracks--track-marker session-id)))
    (ai-tracks--append-to-summary session-id (alist-get 'summary payload))
    (ai-tracks--mark-last-plan-poi-finished marker ts)
    ;; Single raise after every side-effect has landed, so the user
    ;; sees the Track buffer (switched to by `insert-recap-like') with
    ;; the fresh POI selected.
    (ai-tracks--raise-emacs)
    ts))

;;;; Point of Interest

(defvar ai-tracks-poi-categories
  '("Surprise" "Event" "Decision" "Observation" "Other" "Claude-behaviour" "Plan")
  "Categories offered when creating a POI via `ai-tracks-poi-new'.
`Plan' is inserted automatically by `ai-tracks-plan-add' (see the
Claude Code PostToolUse hook on `ExitPlanMode') and is not offered
in the interactive picker in practice, but it is listed here so the
value is part of the closed set.")

(defvar ai-tracks-poi-picker-limit 30
  "Maximum number of recent exchanges shown in the `ai-tracks-poi-new' picker.")

(defvar ai-tracks-poi-picker-width 100
  "Truncation width (in characters) for prompt previews in the
`ai-tracks-poi-new' picker.  Set to nil for no truncation.")

(defun ai-tracks--jsonl-genuine-user-p (obj)
  "Return non-nil if OBJ is a genuine user turn (not a tool_result carrier).
OBJ is a parsed JSONL entry as an alist.  Recognises two shapes:

  1. `type' = \"user\" with `message.content' either a string or a list
     containing at least one block with `type' = \"text\".
  2. `type' = \"queue-operation\", `operation' = \"enqueue\", with a
     `content' string.  Claude Code emits this when the user submits a
     message while a turn is in flight; the text is delivered later as
     a system reminder but never becomes a proper user message."
  (cond
   ((equal (alist-get 'type obj) "user")
    (let* ((msg     (alist-get 'message obj))
           (content (and (listp msg) (alist-get 'content msg))))
      (cond
       ((stringp content) t)
       ((listp content)
        (seq-some (lambda (b)
                    (and (listp b)
                         (equal (alist-get 'type b) "text")))
                  content))
       (t nil))))
   ((and (equal (alist-get 'type obj) "queue-operation")
         (equal (alist-get 'operation obj) "enqueue"))
    (stringp (alist-get 'content obj)))
   (t nil)))

(defun ai-tracks--jsonl-assistant-text (obj)
  "Return concatenated text blocks from assistant JSONL entry OBJ, or nil.
Ignores `thinking' and `tool_use' blocks.  Returns nil for non-assistant
entries or entries with no text content."
  (when (equal (alist-get 'type obj) "assistant")
    (let* ((msg     (alist-get 'message obj))
           (content (and (listp msg) (alist-get 'content msg)))
           parts)
      (when (listp content)
        (dolist (b content)
          (when (and (listp b) (equal (alist-get 'type b) "text"))
            (let ((txt (alist-get 'text b)))
              (when (stringp txt) (push txt parts))))))
      (when parts
        (mapconcat #'identity (nreverse parts) "\n\n")))))

(defun ai-tracks--jsonl-user-text (obj)
  "Return the text of a genuine user JSONL entry OBJ, or nil.
Handles the same two shapes as `ai-tracks--jsonl-genuine-user-p':
a proper user turn (string or text-block-list content), and a
`queue-operation' enqueue with a `content' string.  Returns nil for
non-user entries and for tool_result-only user entries."
  (cond
   ((equal (alist-get 'type obj) "user")
    (let* ((msg     (alist-get 'message obj))
           (content (and (listp msg) (alist-get 'content msg))))
      (cond
       ((stringp content) content)
       ((listp content)
        (let (parts)
          (dolist (b content)
            (when (and (listp b) (equal (alist-get 'type b) "text"))
              (let ((txt (alist-get 'text b)))
                (when (stringp txt) (push txt parts)))))
          (when parts
            (mapconcat #'identity (nreverse parts) "\n\n"))))
       (t nil))))
   ((and (equal (alist-get 'type obj) "queue-operation")
         (equal (alist-get 'operation obj) "enqueue"))
    (let ((c (alist-get 'content obj)))
      (and (stringp c) c)))
   (t nil)))

(defun ai-tracks--jsonl-entry-epoch (obj)
  "Return the epoch seconds of OBJ's `timestamp' field, or nil."
  (let ((ts (alist-get 'timestamp obj)))
    (when (stringp ts)
      (condition-case nil
          (float-time (date-to-time ts))
        (error nil)))))

(defun ai-tracks--read-jsonl (path)
  "Parse PATH as JSONL, returning a list of alists newest-first.
Malformed lines are skipped silently.  Returns nil if PATH is nil or
unreadable."
  (when (and path (file-readable-p path))
    (let (objs)
      (with-temp-buffer
        (insert-file-contents path)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p (string-trim line))
              (condition-case nil
                  (push (json-parse-string line
                                           :object-type 'alist
                                           :array-type 'list
                                           :null-object nil)
                        objs)
                (json-parse-error nil))))
          (forward-line 1)))
      objs)))

(defun ai-tracks--all-exchanges (transcript-path &optional cutoff-epoch)
  "Return every user-prompt / assistant-answer exchange in TRANSCRIPT-PATH.
Result is a list of plists (`:user' text, `:assistant' text) ordered
newest first.  When CUTOFF-EPOCH is non-nil, entries with `timestamp'
strictly greater than CUTOFF-EPOCH are ignored (used by /at:poi to
prune Claude's own reply to the trigger).

Walk semantics: since the transcript is newest→oldest, assistant
text blocks are accumulated until a genuine user turn closes the
round; that user turn is the round's prompt.  Consecutive user
turns at the head (slash-command marker + text body) are skipped
until we have real assistant text to close."
  (let* ((all-objs (ai-tracks--read-jsonl transcript-path))
         (objs (if cutoff-epoch
                   (seq-filter
                    (lambda (o)
                      (let ((e (ai-tracks--jsonl-entry-epoch o)))
                        (or (null e) (<= e cutoff-epoch))))
                    all-objs)
                 all-objs))
         texts
         exchanges)
    (dolist (obj objs)
      (cond
       ((and texts (ai-tracks--jsonl-genuine-user-p obj))
        (push (list :user      (ai-tracks--jsonl-user-text obj)
                    :assistant (mapconcat #'identity
                                          (nreverse texts)
                                          "\n\n"))
              exchanges)
        (setq texts nil))
       (t
        (when-let ((txt (ai-tracks--jsonl-assistant-text obj)))
          (push txt texts)))))
    (nreverse exchanges)))

(defun ai-tracks--nth-exchange (transcript-path n &optional cutoff-epoch)
  "Return the Nth-most-recent exchange from TRANSCRIPT-PATH, or nil.
N is 0-based: 0 is the newest, 1 skips the newest and returns the
one before it, and so on.  Thin wrapper over `ai-tracks--all-exchanges'
so both the picker and the round-based path share one walker."
  (nth n (ai-tracks--all-exchanges transcript-path cutoff-epoch)))

(defun ai-tracks--exchange-label (round exchange width)
  "Return a single-line completion label for EXCHANGE at ROUND.
The user prompt is trimmed, whitespace-collapsed to one line, and
truncated to WIDTH characters (nil = no truncation) with a trailing
`…'.  Formatted as `[ROUND] <preview>' so the numeric round is
visible next to the preview."
  (let* ((prompt (or (plist-get exchange :user) ""))
         (line (replace-regexp-in-string "\\s-+" " " (string-trim prompt)))
         (preview (if (and width (> (length line) width))
                      (concat (substring line 0 width) "…")
                    line)))
    (format "[%d] %s" round preview)))

(defun ai-tracks--pick-exchange (transcript-path &optional cutoff-epoch)
  "Prompt the user via `completing-read' to pick an exchange to embed.
Presents the newest `ai-tracks-poi-picker-limit' exchanges from
TRANSCRIPT-PATH, each labelled by `ai-tracks--exchange-label',
prefixed by a `(no exchange — empty POI)' option that is the default
(RET accepts it).

The completion table declares `display-sort-function' and
`cycle-sort-function' as `identity' so completion frameworks
(vertico, ivy, …) preserve the newest-first insertion order
instead of alphabetising.

Returns the 0-based round index of the chosen exchange, or the
symbol `none' for the empty-POI choice."
  (let* ((exchanges (seq-take (ai-tracks--all-exchanges transcript-path cutoff-epoch)
                              ai-tracks-poi-picker-limit))
         (none-label "(no exchange — empty POI)")
         (alist (cons (cons none-label 'none)
                      (seq-map-indexed
                       (lambda (ex round)
                         (cons (ai-tracks--exchange-label
                                round ex ai-tracks-poi-picker-width)
                               round))
                       exchanges)))
         (candidates (mapcar #'car alist))
         (collection
          (lambda (string pred action)
            (if (eq action 'metadata)
                '(metadata (display-sort-function . identity)
                           (cycle-sort-function . identity))
              (complete-with-action action candidates string pred))))
         (choice (completing-read "POI exchange: "
                                  collection nil t nil nil none-label)))
    (cdr (assoc choice alist))))

(defun ai-tracks--poi-round-status (transcript-path cutoff-epoch n)
  "Return \"ok\" if round N of TRANSCRIPT-PATH is retrievable, else an error string.
Used by the /at:poi wrapper as a blocking pre-check so range errors
surface to Claude via the wrapper's exit code and stderr, rather than
silently producing an empty POI.

N is 0-based (N=0 is the newest exchange).  `ok' means:
TRANSCRIPT-PATH is a readable file and at least N+1 complete
(user prompt + assistant answer) exchanges are available older than
CUTOFF-EPOCH.  Any other outcome returns a short human-readable
diagnostic string."
  (cond
   ((not (and (integerp n) (>= n 0)))
    (format "round must be a non-negative integer, got %S" n))
   ((not (and transcript-path (file-readable-p transcript-path)))
    (format "transcript unreadable: %s" (or transcript-path "<none>")))
   ((not (ai-tracks--nth-exchange transcript-path n cutoff-epoch))
    (format "requested round %d not available (fewer than %d complete exchanges)"
            n (1+ n)))
   (t "ok")))

(defun ai-tracks--markdown-to-org (markdown &optional heading-shift)
  "Convert MARKDOWN string to org via pandoc.
When HEADING-SHIFT is a positive integer, headings are demoted by
that many levels (`--shift-heading-level-by=N').  Used when the
converted body is embedded under a deeper org heading and we do not
want a top-level `*' to escape into a sibling of the surrounding
tree.
Returns a cons (TEXT . WARNING).  WARNING is nil on success; on
failure TEXT is the original MARKDOWN and WARNING is a short message
describing what went wrong (missing pandoc or non-zero exit)."
  (if (not (executable-find "pandoc"))
      (cons markdown "pandoc not found on PATH; inserted raw markdown")
    (with-temp-buffer
      (insert markdown)
      (let* ((shift (or heading-shift 0))
             (args (append (list "-f" "markdown" "-t" "org" "--wrap=preserve")
                           (when (and (integerp shift) (> shift 0))
                             (list (format "--shift-heading-level-by=%d" shift)))))
             (exit (condition-case err
                       (apply #'call-process-region
                              (point-min) (point-max)
                              "pandoc" t t nil args)
                     (error (format "signalled %s" err)))))
        (cond
         ((eq exit 0) (cons (buffer-string) nil))
         ((integerp exit)
          (cons markdown (format "pandoc exited %s; inserted raw markdown" exit)))
         (t
          (cons markdown (format "pandoc %s; inserted raw markdown" exit))))))))

(defun ai-tracks--insert-poi-body (exchange)
  "Insert converted EXCHANGE text at point; return a list of pandoc warnings.
EXCHANGE is a plist from `ai-tracks--nth-exchange' with :user and
:assistant keys (either may be nil).  The user prompt is inserted
inside a `#+begin_quote' block; the assistant answer follows as
plain body.  Both are converted markdown→org via
`ai-tracks--markdown-to-org' with heading-shift 4 so any `#'
headings nest under the level-4 POI heading.

Returns the warnings in insertion order; caller decides how to
surface them."
  (let* ((user-md      (plist-get exchange :user))
         (assistant-md (plist-get exchange :assistant))
         (user-conv      (and user-md      (ai-tracks--markdown-to-org user-md 4)))
         (assistant-conv (and assistant-md (ai-tracks--markdown-to-org assistant-md 4)))
         warnings)
    (when user-conv
      (insert "#+begin_quote\n"
              (string-trim-right (car user-conv)) "\n"
              "#+end_quote\n\n")
      (when (cdr user-conv) (push (cdr user-conv) warnings)))
    (when assistant-conv
      (insert (string-trim-right (car assistant-conv)) "\n\n")
      (when (cdr assistant-conv) (push (cdr assistant-conv) warnings)))
    (nreverse warnings)))


;;;; Plan (Claude Code ExitPlanMode PostToolUse hook)

(defun ai-tracks--tool-response-content-string (tool-response)
  "Return TOOL-RESPONSE's `content' field flattened to a string, or nil.
The `content' field can be either a bare string or a list of
`{type, text}' blocks (Anthropic tool-result shape); this normalises
both to plain text by concatenating the `text' blocks with two
newlines.  Returns nil when there is no content."
  (when (listp tool-response)
    (let ((c (alist-get 'content tool-response)))
      (cond
       ((stringp c) c)
       ((listp c)
        (let (parts)
          (dolist (block c)
            (when (and (listp block)
                       (equal (alist-get 'type block) "text"))
              (when-let ((txt (alist-get 'text block)))
                (push txt parts))))
          (when parts
            (mapconcat #'identity (nreverse parts) "\n\n"))))
       (t nil)))))

(defun ai-tracks--parse-plan-file-path (content-string)
  "Return the plan file path referenced in CONTENT-STRING, or nil.
Claude Code's ExitPlanMode tool result prefixes the plan with a
line like `Your plan has been saved to: /path/to/<slug>.md'."
  (when (and (stringp content-string)
             (string-match "saved to: \\(\\S-+\\.md\\)" content-string))
    (match-string 1 content-string)))

(defun ai-tracks--newest-plan-file ()
  "Return the path of the newest `.md' file in `~/.claude/plans/', or nil.
Fallback used when the tool-response content lacks a parseable
`saved to:' line."
  (let ((dir (expand-file-name "~/.claude/plans/")))
    (when (file-directory-p dir)
      (car (sort (directory-files dir t "\\.md\\'")
                 (lambda (a b)
                   (time-less-p
                    (file-attribute-modification-time (file-attributes b))
                    (file-attribute-modification-time (file-attributes a)))))))))

(defun ai-tracks--plan-classify (content-string)
  "Classify a plan submission from tool-response CONTENT-STRING.
Returns \"accepted\", \"rejected\", or \"edited\".

Heuristic on the visible prose Claude Code emits back to the LLM:
  - \"rejected\", \"did not approve\", or \"doesn't want to proceed\"
    anywhere in the content → \"rejected\"
  - \"edited\" (case-insensitive) or `planWasEdited: true' → \"edited\"
  - default → \"accepted\" (the common case and safest fallback,
    since a mislabelled acceptance is fixed by the next re-plan
    via update-in-place)"
  (cond
   ((not (stringp content-string)) "accepted")
   ((string-match-p "rejected\\|did not approve\\|doesn't want to proceed\\|does not want to proceed"
                    content-string)
    "rejected")
   ((string-match-p "\\bedited\\b\\|planWasEdited[^n]*[tT]"
                    content-string)
    "edited")
   (t "accepted")))

(defun ai-tracks--plan-title-from-markdown (plan-md)
  "Return the text of the first `#'-prefixed line in PLAN-MD, or nil.
Leading whitespace and blank lines are skipped; only the first
non-blank line is inspected."
  (when (stringp plan-md)
    (with-temp-buffer
      (insert plan-md)
      (goto-char (point-min))
      (while (and (not (eobp)) (looking-at-p "^[ \t]*$"))
        (forward-line 1))
      (when (looking-at "^#+[ \t]+\\(.*\\)$")
        (string-trim (match-string 1))))))

(defun ai-tracks--plan-strip-first-heading (plan-md)
  "Return PLAN-MD with its first `#'-prefixed line removed.
No-op when the first non-blank line is not a heading."
  (if (not (stringp plan-md))
      ""
    (with-temp-buffer
      (insert plan-md)
      (goto-char (point-min))
      (while (and (not (eobp)) (looking-at-p "^[ \t]*$"))
        (forward-line 1))
      (when (looking-at "^#+[ \t]+")
        (delete-region (line-beginning-position)
                       (progn (forward-line 1) (point))))
      (buffer-string))))

(defun ai-tracks--read-trailing-plan-poi-drawer (marker)
  "If the bottommost level-4 POI under MARKER is a Plan POI, return
its revision-relevant drawer keys as an alist:

  (revisions        . <string, may be nil>)
  (first-submitted  . <string, may be nil>)
  (previous-status  . <string, may be nil — the prior :POI-SUB-CATEGORY:>)

Returns nil when the trailing POI is not a Plan POI (which is the
initial-plan case for the caller: no prior to carry over)."
  (org-with-point-at marker
    (save-restriction
      (org-narrow-to-subtree)
      (goto-char (point-max))
      (when (re-search-backward "^\\*\\{4\\} " nil t)
        (when (equal (org-entry-get (point) "POI-CATEGORY") "Plan")
          (list (cons 'revisions       (org-entry-get (point) "PLAN-REVISIONS"))
                (cons 'first-submitted (org-entry-get (point) "PLAN-FIRST-SUBMITTED"))
                (cons 'previous-status (org-entry-get (point) "POI-SUB-CATEGORY"))))))))

(defun ai-tracks--delete-trailing-plan-poi (marker)
  "Delete the bottommost level-4 POI under MARKER if it is a Plan POI.
Returns non-nil if a POI was deleted."
  (org-with-point-at marker
    (save-restriction
      (org-narrow-to-subtree)
      (goto-char (point-max))
      (when (re-search-backward "^\\*\\{4\\} " nil t)
        (when (equal (org-entry-get (point) "POI-CATEGORY") "Plan")
          (let ((beg (point))
                (end (save-excursion (org-end-of-subtree t t))))
            (delete-region beg end)
            t))))))

(defun ai-tracks--mark-last-plan-poi-finished (marker &optional ts)
  "Walk backward under MARKER's subtree to the most recent Plan POI
and stamp `:PLAN-FINISHED-AT: TS' on it (defaulting to now) unless
the key is already set.  No-op if no Plan POI exists.  Called from
two places:
  1. `ai-tracks-plan-add' when the incoming ExitPlanMode is a new
     plan (prior sub-category was `accepted' or `edited'), before
     appending the fresh POI — the outgoing plan is thus recorded
     as done at the moment the next one starts.
  2. `ai-tracks-end-session-add' — end-of-session stamps any
     outstanding Plan POI as finished at the wrap-up time."
  (let ((stamp (or ts (format-time-string "[%Y-%m-%d %a %H:%M]"))))
    (org-with-point-at marker
      (save-restriction
        (org-narrow-to-subtree)
        (goto-char (point-max))
        (let (done)
          (while (and (not done)
                      (re-search-backward "^\\*\\{4\\} " nil t))
            (when (equal (org-entry-get (point) "POI-CATEGORY") "Plan")
              (setq done t)
              (unless (org-entry-get (point) "PLAN-FINISHED-AT")
                (org-entry-put (point) "PLAN-FINISHED-AT" stamp)
                (save-buffer)))))))))

(defun ai-tracks--plan-read-markdown (content-string)
  "Return the plan markdown from disk for the current ExitPlanMode fire.
CONTENT-STRING is `tool_response.content' flattened by
`ai-tracks--tool-response-content-string'.  We prefer to extract
the plan file path from that string (Claude Code emits a
`Your plan has been saved to: <path>' line) and read from disk; if
the regex misses, we fall back to the newest file in
`~/.claude/plans/'.  Returns nil when neither path yields a
readable file.

Reading from disk rather than parsing the plan out of the content
prose is deliberate: the disk file is canonical; the content prose
also carries the plan verbatim but is bracketed by human-facing
framing (`## Approved Plan:', etc.) that would need stripping."
  (let* ((from-content (ai-tracks--parse-plan-file-path content-string))
         (path (or (and from-content
                        (file-readable-p from-content)
                        from-content)
                   (ai-tracks--newest-plan-file))))
    (when (and path (file-readable-p path))
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

;;;###autoload
(defun ai-tracks-plan-add (json-file)
  "Insert or update a Plan POI under the Track for the session in JSON-FILE.
JSON-FILE is a path to a Claude Code PostToolUse hook payload for the
`ExitPlanMode' tool; it is read and deleted.

Payload fields consulted:
  session_id                             the Track's Claude UUID.
  tool_response.content                  the tool result text sent
                                         back to the LLM.  We extract
                                         the plan file path from this
                                         string (a `Your plan has been
                                         saved to: <path>' line
                                         emitted by Claude Code) and
                                         then read the plan markdown
                                         from disk.  The same string
                                         drives sub-category
                                         classification via
                                         `ai-tracks--plan-classify'.

The tool `input' visible to hooks is empty (`{}') — the LLM invokes
`ExitPlanMode' with no arguments and Claude Code assembles the plan
internally from the on-disk file.  Do not look for the plan in
`tool_input'.

If the bottommost level-4 POI under the Track already has
:POI-CATEGORY: Plan, it is deleted first — this is how re-plans
overwrite the prior plan in place.  A fresh POI is then appended.

POI title is the first `#'-prefixed line of the plan markdown
with the `#'s stripped, or (fallback) `Plan [<date>]' when the plan
carries no heading.  Body is the remainder, converted to org via
pandoc with `--shift-heading-level-by=4' so any headings become
level-5 sub-sections of the POI rather than top-level siblings.

Drawer keys written:
  :POI-CATEGORY:      Plan
  :POI-SUB-CATEGORY:  accepted | rejected | edited
  :CLAUDE-PLANNED:    inactive timestamp.

Missing-Track case: warns via `display-warning' and returns nil.
Missing-plan-content case (no path parseable, no fallback file):
same treatment.  The hook must tolerate both because Claude Code
fires PostToolUse unconditionally."
  (interactive "fClaude Code PostToolUse JSON file: ")
  (let* ((payload    (ai-tracks--read-payload json-file))
         (session-id (alist-get 'session_id payload))
         (tool-resp  (alist-get 'tool_response payload))
         (content    (ai-tracks--tool-response-content-string tool-resp))
         (plan-md    (ai-tracks--plan-read-markdown content))
         (sub-cat    (ai-tracks--plan-classify content))
         (title-text (ai-tracks--plan-title-from-markdown plan-md))
         (marker     (condition-case _
                         (and (stringp session-id)
                              (ai-tracks--track-marker session-id))
                       (user-error nil))))
    (cond
     ((not marker)
      (display-warning
       'ai-tracks
       (format "No Track for session %s; Plan POI skipped"
               (or session-id "<no session_id>"))
       :warning)
      nil)
     ((not (and (stringp plan-md)
                (not (string-empty-p (string-trim plan-md)))))
      (display-warning
       'ai-tracks
       (format "No plan content on disk for session %s; Plan POI skipped"
               session-id)
       :warning)
      nil)
     (t
      (let* ((now      (current-time))
             (ts       (format-time-string "[%Y-%m-%d %a %H:%M]" now))
             (prefix   (format-time-string "Plan [%Y-%m-%d %a %H:%M]" now))
             (title    (if (and title-text (not (string-empty-p title-text)))
                           (concat prefix " " title-text)
                         prefix))
             (body-md  (ai-tracks--plan-strip-first-heading plan-md))
             (conv     (ai-tracks--markdown-to-org body-md 4))
             (body-org (string-trim-right (or (car conv) "")))
             ;; Decide whether this fire is a revision of the
             ;; trailing Plan POI or a genuinely new plan.  Rule:
             ;; the trailing POI's :POI-SUB-CATEGORY: is `rejected'
             ;; iff Claude Code is expected to re-plan → revision.
             ;; `accepted' and `edited' are terminal from the
             ;; user's perspective; a fresh ExitPlanMode after
             ;; either is a new plan.  When there is no trailing
             ;; Plan POI at all, this is an initial plan (also
             ;; treated as append, but with no prior to finish).
             (prior         (ai-tracks--read-trailing-plan-poi-drawer marker))
             (prior-status  (and prior (alist-get 'previous-status prior)))
             (is-revision   (equal prior-status "rejected"))
             ;; Revision-only bookkeeping (values default so the
             ;; new-plan / initial-plan branch just gets rev=1 and
             ;; first-submitted=now).
             (prev-revs     (and is-revision
                                 (let ((v (alist-get 'revisions prior)))
                                   (and v (string-to-number v)))))
             (rev-count     (if is-revision (1+ (or prev-revs 0)) 1))
             (first-sub     (or (and is-revision
                                     (alist-get 'first-submitted prior))
                                ts))
             (prev-stat     (and is-revision prior-status)))
        (cond
         (is-revision
          (ai-tracks--delete-trailing-plan-poi marker))
         (prior
          ;; New plan after an accepted/edited prior — stamp the
          ;; prior as finished before appending.
          (ai-tracks--mark-last-plan-poi-finished marker ts)))
        (org-with-point-at marker
          (goto-char (save-excursion (org-end-of-subtree t t)))
          (unless (bolp) (insert "\n"))
          (let ((heading-start (point)))
            (insert (format "**** %s\n:PROPERTIES:\n" title))
            (insert (format ":POI-CATEGORY: Plan\n"))
            (insert (format ":POI-SUB-CATEGORY: %s\n" sub-cat))
            (insert (format ":PLAN-REVISIONS: %d\n" rev-count))
            (insert (format ":PLAN-FIRST-SUBMITTED: %s\n" first-sub))
            (when prev-stat
              (insert (format ":PLAN-PREVIOUS-STATUS: %s\n" prev-stat)))
            (insert (format ":CLAUDE-PLANNED: %s\n:END:\n" ts))
            (unless (string-empty-p body-org)
              (insert body-org "\n"))
            (save-buffer)
            ;; Fold so the Plan POI shows only its heading and any
            ;; sub-headings (from `##'-in-plan → level-5+ after
            ;; pandoc's --shift-heading-level-by=4), hiding their
            ;; bodies.  Keeps the Track scannable.
            (goto-char heading-start)
            (outline-hide-subtree)
            (outline-show-branches)))
        (when (cdr conv)
          (message "ai-tracks: %s" (cdr conv)))
        (ai-tracks--raise-emacs)
        ts)))))

;;;; Empty POI (user-invoked from Emacs, not via a slash command)

(defun ai-tracks--enclosing-track-marker ()
  "Return a marker at the enclosing Track heading, or nil.
Walks up from point to the nearest level-3 heading and checks that
its `:ID:' starts with `claude-'; nil otherwise.  A nil return
means point is not inside an ai-tracks Track."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t) t)
      (while (and (> (or (org-current-level) 0) 3)
                  (org-up-heading-safe)))
      (when (and (equal (org-current-level) 3)
                 (let ((id (org-entry-get (point) "ID")))
                   (and id (string-prefix-p "claude-" id))))
        (point-marker)))))

;;;###autoload
(defun ai-tracks-poi-new (&optional round category session-id transcript-path cutoff-epoch)
  "Append an explicit POI under a Track and optionally embed a prior exchange.
Single implementation for both the in-Emacs `M-x ai-tracks-poi-new'
path and the `/at:poi' bash wrapper.

ROUND selects which exchange (if any) to embed as the POI body:
  - integer (0-based): 0 is the newest, 1 skips it and picks the one
    before, and so on.
  - symbol `none': skip embedding — the POI is created with just its
    heading and drawer.
  - nil: interactive — prompt via `ai-tracks--pick-exchange'
    (`completing-read' menu of truncated prompts, default is `none').

CATEGORY is one of `ai-tracks-poi-categories'; nil prompts via
`completing-read'.

Track lookup:
- When SESSION-ID is non-nil (typically from the bash wrapper), the
  Track is looked up by ID via `ai-tracks--track-marker'.
- When SESSION-ID is nil (interactive path), the enclosing Track is
  located from point; SESSION-ID is then derived from its `:ID:'
  (stripping the `claude-' prefix).

When TRANSCRIPT-PATH is nil, globs
`~/.claude/projects/*/<session-id>.jsonl'.  CUTOFF-EPOCH is a Unix
timestamp; JSONL entries newer than it are ignored (the wrapper
passes its own invocation time so Claude's response to /at:poi is
not pulled in).  Interactive callers leave it nil.

When embedding, the user prompt and Claude's answer are converted
markdown→org via pandoc and inserted as the POI body: the prompt
inside a `#+begin_quote' block, followed by the answer.  Point
lands on a blank line below so the user can add their own
commentary.  When ROUND is `none', point lands on the first line
under the drawer instead.

Signals `user-error' — inserting nothing — when the Track cannot
be located, no transcript file exists for the session, or an
integer ROUND is out of range.  Returns the POI's timestamp string
on success."
  (interactive)
  (let ((track-marker (if session-id
                          (ai-tracks--track-marker session-id)
                        (or (ai-tracks--enclosing-track-marker)
                            (user-error
                             "ai-tracks: point is not inside an ai-tracks Track")))))
    (let* ((session-id
            (or session-id
                (let ((tid (org-with-point-at track-marker
                             (org-entry-get (point) "ID"))))
                  (substring tid (length "claude-")))))
           (transcript-path
            (or transcript-path
                (car (file-expand-wildcards
                      (expand-file-name
                       (format "~/.claude/projects/*/%s.jsonl" session-id)))))))
      (unless (and transcript-path (file-readable-p transcript-path))
        (user-error "ai-tracks: no transcript found for session %s" session-id))
      (let* ((round (cond ((eq round 'none) 'none)
                          ((integerp round) round)
                          (t (ai-tracks--pick-exchange transcript-path cutoff-epoch))))
             (category (or category
                           (completing-read "POI category: "
                                            ai-tracks-poi-categories nil t))))
        (unless (eq round 'none)
          (let ((status (ai-tracks--poi-round-status transcript-path cutoff-epoch round)))
            (unless (equal status "ok")
              (user-error "ai-tracks: %s" status))))
        (let* ((now (current-time))
               (title (format-time-string "POI [%Y-%m-%d %a %H:%M]" now))
               (ts (format-time-string "[%Y-%m-%d %a %H:%M]" now)))
          (switch-to-buffer (marker-buffer track-marker))
          (goto-char (marker-position track-marker))
          (goto-char (save-excursion (org-end-of-subtree t t)))
          (unless (bolp) (insert "\n"))
          (insert (format "**** %s\n:PROPERTIES:\n:POI-CATEGORY: %s\n:CLAUDE-POI: %s\n:END:\n"
                          title category ts))
          (unless (eq round 'none)
            (let* ((exchange (ai-tracks--nth-exchange transcript-path round cutoff-epoch))
                   (warnings (ai-tracks--insert-poi-body exchange)))
              (when warnings
                (message "ai-tracks: %s"
                         (mapconcat #'identity warnings "; ")))))
          (org-reveal)
          (save-buffer)
          (ai-tracks--raise-emacs)
          ts)))))

;;;; Navigation

(declare-function org-roam-node-from-id "org-roam-node")
(declare-function org-roam-node-visit   "org-roam-node")

;;;###autoload
(defun ai-tracks-goto-track (session-id)
  "Visit the Track for SESSION-ID via org-roam node navigation.
Signals a user-error if no Track is registered for this session."
  (let* ((id   (format "claude-%s" session-id))
         (node (org-roam-node-from-id id)))
    (unless node
      (user-error "ai-tracks: no Track with ID %s; run /at:track-start first" id))
    (org-roam-node-visit node)
    (ai-tracks--raise-emacs)))

;;;; Magit / commit integration

(declare-function magit-toplevel     "magit-git")
(declare-function magit-rev-parse    "magit-git")
(declare-function magit-git-string   "magit-git")
(declare-function magit-git-lines    "magit-git")
(declare-function magit-git-dir      "magit-git")

(defun ai-tracks--commit-cwd ()
  "Return the git worktree root at `default-directory', or nil."
  (and (fboundp 'magit-toplevel) (magit-toplevel)))

(declare-function magit-get "magit-git")

(defun ai-tracks--origin-url ()
  "Return the URL of the `origin' remote, or nil if none is configured."
  (and (fboundp 'magit-get) (magit-get "remote" "origin" "url")))

(defun ai-tracks--parse-github-remote (url)
  "If URL is a GitHub origin URL, return (OWNER . REPO); else nil.
Accepts SSH, HTTPS, and ssh:// forms and strips a trailing .git."
  (when url
    (let ((cleaned (replace-regexp-in-string "\\.git\\'" "" url)))
      (when (string-match
             "\\`\\(?:git@github\\.com:\\|https?://github\\.com/\\|ssh://git@github\\.com/\\)\\([^/]+\\)/\\([^/]+\\)\\'"
             cleaned)
        (cons (match-string 1 cleaned) (match-string 2 cleaned))))))

(defun ai-tracks--github-commit-url (sha)
  "Return the GitHub commit URL for SHA, or nil if origin is not on GitHub."
  (when-let* ((remote (ai-tracks--origin-url))
              (parsed (ai-tracks--parse-github-remote remote)))
    (format "https://github.com/%s/%s/commit/%s"
            (car parsed) (cdr parsed) sha)))

(defun ai-tracks--commit-info ()
  "Return a plist describing HEAD of the git repo at `default-directory'."
  (let* ((default-directory (or (ai-tracks--commit-cwd) default-directory))
         (sha (magit-rev-parse "HEAD")))
    (list :cwd     default-directory
          :sha     sha
          :short   (magit-rev-parse "--short" "HEAD")
          :url     (ai-tracks--github-commit-url sha)
          :subject (magit-git-string "log" "-1" "--pretty=%s" "HEAD")
          :body    (mapconcat #'identity
                              (magit-git-lines "log" "-1" "--pretty=%b" "HEAD")
                              "\n")
          :author  (magit-git-string "log" "-1" "--pretty=%aN <%aE>" "HEAD")
          :files   (magit-git-lines "show" "--name-only"
                                    "--pretty=format:" "HEAD"))))

(defun ai-tracks--rebase-in-progress-p ()
  "Return non-nil if a rebase or cherry-pick is in progress."
  (let ((gitdir (and (fboundp 'magit-git-dir) (magit-git-dir))))
    (and gitdir
         (or (file-exists-p (expand-file-name "rebase-apply" gitdir))
             (file-exists-p (expand-file-name "rebase-merge" gitdir))
             (file-exists-p (expand-file-name "CHERRY_PICK_HEAD" gitdir))))))

(defun ai-tracks--commit-candidates (commit-cwd)
  "Return org-roam nodes whose :CLAUDE-CWD: is COMMIT-CWD or an ancestor.
Sorted by :CLAUDE-STARTED: descending (most recent first)."
  (let ((commit-dir (file-name-as-directory (expand-file-name commit-cwd))))
    (sort
     (seq-filter
      (lambda (node)
        (and (string-prefix-p "claude-" (org-roam-node-id node))
             (let ((cwd (ai-tracks--unwrap-cwd
                         (cdr (assoc "CLAUDE-CWD"
                                     (org-roam-node-properties node))))))
               (and cwd
                    (string-prefix-p
                     (file-name-as-directory (expand-file-name cwd))
                     commit-dir)))))
      (org-roam-node-list))
     (lambda (a b)
       (string> (or (cdr (assoc "CLAUDE-STARTED"
                                (org-roam-node-properties a))) "")
                (or (cdr (assoc "CLAUDE-STARTED"
                                (org-roam-node-properties b))) ""))))))

(defun ai-tracks--candidate-label (node)
  "Return a display label for NODE candidate in the picker.
Formatted as `<parent> -- <track-title>' so the user can tell
Tracks apart by the enclosing level-1 org-roam node (which
carries the topic).  Falls back to `??' when NODE has no
outline path (e.g. a Track sitting directly at file level).
Uses the org-roam DB only — no file I/O."
  (format "%s -- %s"
          (or (car (org-roam-node-olp node)) "??")
          (org-roam-node-title node)))

(defun ai-tracks--pick-track (candidates)
  "Prompt the user to pick a Track from CANDIDATES, or (skip).
CANDIDATES arrive newest-first (sorted by `:CLAUDE-STARTED:'
descending in `ai-tracks--commit-candidates').  The completion
table declares `display-sort-function' and `cycle-sort-function'
as `identity' so vertico/ivy/… preserve that order instead of
alphabetising.  Returns the chosen org-roam-node, or nil for
skip / abort."
  (let* ((labels (mapcar (lambda (n) (cons (ai-tracks--candidate-label n) n))
                         candidates))
         (skip   "(skip — not a tracked commit)")
         (choices (append (mapcar #'car labels) (list skip)))
         (collection
          (lambda (string pred action)
            (if (eq action 'metadata)
                '(metadata (display-sort-function . identity)
                           (cycle-sort-function . identity))
              (complete-with-action action choices string pred))))
         (choice (completing-read
                  "Attach commit to Track: "
                  collection nil t nil nil (car choices))))
    (unless (string= choice skip)
      (cdr (assoc choice labels)))))

(defun ai-tracks--insert-commit (node info)
  "Insert a level-4 Commit heading under NODE for the commit INFO plist.
Switches to the node's buffer, positions point at the end of the new
entry so the user can add or edit, and saves the buffer immediately."
  (let ((buffer (find-file-noselect (org-roam-node-file node)))
        (pos    (org-roam-node-point node)))
    (switch-to-buffer buffer)
    (widen)
    (goto-char pos)
    (goto-char (save-excursion (org-end-of-subtree t t)))
    (unless (bolp) (insert "\n"))
    (let* ((now (current-time))
           (ts  (format-time-string "[%Y-%m-%d %a %H:%M]" now)))
      (insert (format
               "**** Commit %s %s — %s\n:PROPERTIES:\n:POI-CATEGORY: Commit\n:CLAUDE-COMMIT: %s\n:COMMIT-SHA: %s\n:COMMIT-AUTHOR: %s\n:END:\n"
               ts
               (or (plist-get info :short) "")
               (or (plist-get info :subject) "")
               ts
               (or (plist-get info :sha) "")
               (or (plist-get info :author) ""))))
    (when-let ((url (plist-get info :url)))
      (insert (format "\n[[%s]]\n" url)))
    (let ((body (plist-get info :body)))
      (when body
        (let ((trimmed (string-trim body)))
          (unless (string-empty-p trimmed)
            (insert "\n" trimmed "\n")))))
    (let ((files (plist-get info :files)))
      (when files
        (insert "\nFiles:\n")
        (dolist (f files)
          (unless (string-empty-p f)
            (insert (format "- %s\n" f))))))
    (save-buffer)
    (org-reveal)))

(defun ai-tracks-after-commit ()
  "Post-commit handler for `ai-tracks-magit-mode'.
Looks up candidate Tracks for the current commit's cwd, prompts the
user for one (or skip), and inserts a level-4 Commit heading under it."
  (unless (ai-tracks--rebase-in-progress-p)
    (let ((cwd (ai-tracks--commit-cwd)))
      (when cwd
        (let ((candidates (ai-tracks--commit-candidates cwd)))
          (when candidates
            (let* ((info (ai-tracks--commit-info))
                   (chosen (ai-tracks--pick-track candidates)))
              (when chosen
                (ai-tracks--insert-commit chosen info)
                (message "ai-tracks: commit %s attached to %s"
                         (plist-get info :short)
                         (org-roam-node-title chosen))))))))))

;;;###autoload
(define-minor-mode ai-tracks-magit-mode
  "Global minor mode integrating ai-tracks with magit commits.
When enabled, each magit commit — via the commit message buffer or a
`--no-edit' style command — prompts in Emacs for a Track (found via
the org-roam DB, filtered by :CLAUDE-CWD:) and inserts a level-4
Commit heading under the chosen Track.  Commits made from the shell
outside Emacs are not affected.

On by default: enabled when the module is loaded."
  :global t
  :lighter " AITrk"
  (if ai-tracks-magit-mode
      (progn
        (add-hook 'git-commit-post-finish-hook #'ai-tracks-after-commit)
        (add-hook 'magit-post-commit-hook      #'ai-tracks-after-commit))
    (remove-hook 'git-commit-post-finish-hook  #'ai-tracks-after-commit)
    (remove-hook 'magit-post-commit-hook       #'ai-tracks-after-commit)))

(ai-tracks-magit-mode 1)

(provide 'ai-tracks)

;;; ai-tracks.el ends here

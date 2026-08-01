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
    (org-roam-capture-)
    (ai-tracks--raise-emacs)))

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
    (prog1
        (or latest
            (user-error "ai-tracks: no boundary timestamp on Track for %s"
                        session-id))
      (ai-tracks--raise-emacs))))

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
value."
  (let* ((marker (ai-tracks--track-marker session-id))
         (now   (current-time))
         (title (format-time-string
                 (concat title-prefix " [%Y-%m-%d %a %H:%M]") now))
         (ts    (format-time-string "[%Y-%m-%d %a %H:%M]" now))
         (sections '((files     . "Files touched")
                     (decisions . "Decisions")
                     (open      . "Open threads")
                     (next      . "Next"))))
    (org-with-point-at marker
      (goto-char (save-excursion (org-end-of-subtree t t)))
      (unless (bolp) (insert "\n"))
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
      (save-buffer))
    (ai-tracks--raise-emacs)
    ts))

(defun ai-tracks--find-or-create-summary-node (track-marker)
  "Return a marker at the Summary heading under the Track at TRACK-MARKER.
Creates a level-4 `Summary' heading as the first child of the Track
if it doesn't already exist.  The new heading carries
:POI-CATEGORY: Summary and an initially-blank :CLAUDE-SUMMARIZED:."
  (org-with-point-at track-marker
    (save-restriction
      (org-narrow-to-subtree)
      (goto-char (point-min))
      (let ((existing (save-excursion
                        (when (re-search-forward "^\\*\\{4\\} Summary$" nil t)
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
            (let ((heading-start (point)))
              (insert "**** Summary\n"
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
  (ai-tracks--insert-recap-like
   session-id (ai-tracks--read-payload json-file)
   "Recap" "CLAUDE-RECAPPED" "Recap"))

(defun ai-tracks-end-session-add (session-id json-file)
  "Append an End-of-session POI and update the Track's rolling Summary.
The End-of-session POI is semantically a Recap (same category and
drawer key) with a different title.  Additionally, the `summary'
bullets are appended as a new dated group to the Track's Summary
node (created as the first level-4 child on demand).  Same JSON
schema as `ai-tracks-recap-add'."
  (let* ((payload (ai-tracks--read-payload json-file))
         (ts (ai-tracks--insert-recap-like
              session-id payload
              "End of session" "CLAUDE-RECAPPED" "Recap")))
    (ai-tracks--append-to-summary session-id (alist-get 'summary payload))
    ts))

;;;; Point of Interest

(defvar ai-tracks-poi-categories
  '("Surprise" "Event" "Decision" "Observation" "Other" "Claude-behaviour" "Plan")
  "Categories offered when creating a POI via `ai-tracks-poi-add'.
`Plan' is inserted automatically by `ai-tracks-plan-add' (see the
Claude Code PostToolUse hook on `ExitPlanMode') and is not offered
in the interactive picker in practice, but it is listed here so the
value is part of the closed set.")

(defun ai-tracks--jsonl-genuine-user-p (obj)g
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

(defun ai-tracks--last-exchange (transcript-path &optional cutoff-epoch)
  "Return a plist describing the last user-prompt / assistant-answer exchange.
Reads TRANSCRIPT-PATH (a JSONL file).  When CUTOFF-EPOCH is non-nil,
entries with `timestamp' strictly greater than CUTOFF-EPOCH are
ignored — this prunes anything Claude wrote in response to the
slash-command trigger itself (which lands in the transcript before
Emacs gets a chance to read it).

The plist has:
  :user       string — text of the genuine user message that triggered
                       Claude's answer (the one before the slash-command
                       trigger), or nil if not found.
  :assistant  string — concatenated `text' blocks from all assistant
                       messages between the slash-command trigger (if
                       present) and the previous genuine user message.
Returns nil when no assistant text can be extracted."
  (let* ((all-objs (ai-tracks--read-jsonl transcript-path))
         (objs (if cutoff-epoch
                   (seq-filter
                    (lambda (o)
                      (let ((e (ai-tracks--jsonl-entry-epoch o)))
                        (or (null e) (<= e cutoff-epoch))))
                    all-objs)
                 all-objs))
         (done nil)
         (prev-user nil)
         texts)
    ;; Walk newest→oldest.  Skip everything (including any consecutive
    ;; genuine user turns — slash commands leave two: a command-name
    ;; marker plus a text-body entry) until we start collecting
    ;; assistant text.  Once we have text, the next genuine user turn
    ;; is the actual prior prompt.
    (dolist (obj objs)
      (unless done
        (cond
         ((and texts (ai-tracks--jsonl-genuine-user-p obj))
          (setq prev-user (ai-tracks--jsonl-user-text obj))
          (setq done t))
         (t
          (when-let ((txt (ai-tracks--jsonl-assistant-text obj)))
            (push txt texts))))))
    (when texts
      (list :user      prev-user
            :assistant (mapconcat #'identity texts "\n\n")))))

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

(defun ai-tracks-poi-add (session-id &optional transcript-path cutoff-epoch)
  "Insert a level-4 explicit-POI heading under the Track for SESSION-ID.
Prompts for a category from `ai-tracks-poi-categories', writes the
drawer, and switches to the org file's buffer.

When TRANSCRIPT-PATH is a readable JSONL file (this session's Claude
Code transcript), extracts the previous user prompt and Claude's last
answer via `ai-tracks--last-exchange', converts each markdown→org via
pandoc, and inserts them as the POI body: the user prompt inside a
`#+begin_quote' block, followed by Claude's answer.  Point lands on a
blank line below so the user can add their own commentary.

CUTOFF-EPOCH is a Unix timestamp (seconds); JSONL entries newer than
this are ignored during extraction.  The wrapper passes its own
invocation time so Claude's response to the /at:poi trigger itself is
not pulled into the POI."
  (let* ((marker (ai-tracks--track-marker session-id))
         (category (completing-read
                    "POI category: "
                    ai-tracks-poi-categories
                    nil t))
         (now (current-time))
         (title (format-time-string "POI [%Y-%m-%d %a %H:%M]" now))
         (ts (format-time-string "[%Y-%m-%d %a %H:%M]" now))
         (exchange (and transcript-path
                        (ai-tracks--last-exchange transcript-path cutoff-epoch)))
         (user-md      (plist-get exchange :user))
         (assistant-md (plist-get exchange :assistant))
         (user-conv      (and user-md      (ai-tracks--markdown-to-org user-md)))
         (assistant-conv (and assistant-md (ai-tracks--markdown-to-org assistant-md)))
         warnings)
    (switch-to-buffer (marker-buffer marker))
    (goto-char (marker-position marker))
    (goto-char (save-excursion (org-end-of-subtree t t)))
    (unless (bolp) (insert "\n"))
    (insert (format "**** %s\n:PROPERTIES:\n:POI-CATEGORY: %s\n:CLAUDE-POI: %s\n:END:\n"
                    title category ts))
    (when user-conv
      (insert "#+begin_quote\n")
      (let ((body (string-trim-right (car user-conv))))
        (insert body "\n"))
      (insert "#+end_quote\n\n")
      (when (cdr user-conv) (push (cdr user-conv) warnings)))
    (when assistant-conv
      (let ((body (string-trim-right (car assistant-conv))))
        (insert body "\n\n"))
      (when (cdr assistant-conv) (push (cdr assistant-conv) warnings)))
    (org-reveal)
    (save-buffer)
    (when warnings
      (message "ai-tracks: %s" (mapconcat #'identity (nreverse warnings) "; ")))
    (ai-tracks--raise-emacs)
    ts))

;;;; Plan (Claude Code ExitPlanMode PostToolUse hook)

(defun ai-tracks--plan-classify (tool-response)
  "Classify a plan submission from TOOL-RESPONSE (parsed alist).
Returns one of \"accepted\", \"rejected\", or \"edited\".

Heuristic — Claude Code's exact response shape for `ExitPlanMode' is
not documented; we look at the fields the binary is known to emit
on success (`data.plan', `data.filePath', `data.planWasEdited') and
common rejection markers (`isError'), and fall through to
\"accepted\" for any unrecognised shape."
  (let* ((data (and (listp tool-response)
                    (alist-get 'data tool-response)))
         (edited (or (and (listp data) (alist-get 'planWasEdited data))
                     (and (listp tool-response)
                          (alist-get 'planWasEdited tool-response))))
         (is-error (and (listp tool-response)
                        (alist-get 'isError tool-response)))
         (has-plan-shape
          (and (listp data)
               (or (alist-get 'plan data)
                   (alist-get 'filePath data)))))
    (cond
     (edited "edited")
     (is-error "rejected")
     (has-plan-shape "accepted")
     (t "accepted"))))

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

;;;###autoload
(defun ai-tracks-plan-add (json-file)
  "Insert or update a Plan POI under the Track for the session in JSON-FILE.
JSON-FILE is a path to a Claude Code PostToolUse hook payload for the
`ExitPlanMode' tool; it is read and deleted.

Payload fields consulted:
  session_id                                the Track's Claude UUID.
  tool_input.plan                           plan markdown (injected
                                            from disk by Claude Code's
                                            normalizeToolInput step).
  tool_response.data.plan / .filePath /
    .planWasEdited                          drive the sub-category
                                            classification via
                                            `ai-tracks--plan-classify'.

If the bottommost level-4 POI under the Track already has
:POI-CATEGORY: Plan, it is deleted first — this is how re-plans
overwrite the prior plan in place.  A fresh POI is then appended.

The POI title is the first `#'-prefixed line of the plan markdown
with the `#'s stripped, or (fallback) `Plan [<date>]' when the plan
carries no heading.  The body is the remainder of the markdown,
converted to org via pandoc with `--shift-heading-level-by=4' so any
headings become level-5 sub-sections of the POI rather than
top-level siblings of the surrounding org tree.

Drawer keys written:
  :POI-CATEGORY:      Plan
  :POI-SUB-CATEGORY:  accepted | rejected | edited
  :CLAUDE-PLANNED:    inactive timestamp.

Missing-Track case: emits a warning via `display-warning' and
returns nil.  The hook must tolerate projects without ai-tracks
Tracks because Claude Code fires PostToolUse unconditionally."
  (interactive "fClaude Code PostToolUse JSON file: ")
  (let* ((payload    (ai-tracks--read-payload json-file))
         (session-id (alist-get 'session_id payload))
         (tool-input (alist-get 'tool_input payload))
         (tool-resp  (alist-get 'tool_response payload))
         (plan-md    (and (listp tool-input) (alist-get 'plan tool-input)))
         (sub-cat    (ai-tracks--plan-classify tool-resp))
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
       (format "No plan content in payload for session %s; Plan POI skipped"
               session-id)
       :warning)
      nil)
     (t
      (let* ((now      (current-time))
             (ts       (format-time-string "[%Y-%m-%d %a %H:%M]" now))
             (fallback (format-time-string "Plan [%Y-%m-%d %a %H:%M]" now))
             (title    (if (and title-text (not (string-empty-p title-text)))
                           title-text
                         fallback))
             (body-md  (ai-tracks--plan-strip-first-heading plan-md))
             (conv     (ai-tracks--markdown-to-org body-md 4))
             (body-org (string-trim-right (or (car conv) ""))))
        (ai-tracks--delete-trailing-plan-poi marker)
        (org-with-point-at marker
          (goto-char (save-excursion (org-end-of-subtree t t)))
          (unless (bolp) (insert "\n"))
          (insert (format
                   "**** %s\n:PROPERTIES:\n:POI-CATEGORY: Plan\n:POI-SUB-CATEGORY: %s\n:CLAUDE-PLANNED: %s\n:END:\n"
                   title sub-cat ts))
          (unless (string-empty-p body-org)
            (insert body-org "\n"))
          (save-buffer))
        (when (cdr conv)
          (message "ai-tracks: %s" (cdr conv)))
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
Uses the node title from the org-roam DB — no file I/O."
  (org-roam-node-title node))

(defun ai-tracks--pick-track (candidates)
  "Prompt the user to pick a Track from CANDIDATES, or (skip).
Returns the chosen org-roam-node, or nil for skip / abort."
  (let* ((labels (mapcar (lambda (n) (cons (ai-tracks--candidate-label n) n))
                         candidates))
         (skip   "(skip — not a tracked commit)")
         (choices (append (mapcar #'car labels) (list skip)))
         (choice (completing-read
                  "Attach commit to Track: "
                  choices nil t nil nil (car choices))))
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
    (let ((now (current-time)))
      (insert (format
               "**** Commit %s — %s\n:PROPERTIES:\n:POI-CATEGORY: Commit\n:CLAUDE-COMMIT: %s\n:COMMIT-SHA: %s\n:COMMIT-AUTHOR: %s\n:END:\n"
               (or (plist-get info :short) "")
               (or (plist-get info :subject) "")
               (format-time-string "[%Y-%m-%d %a %H:%M]" now)
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
outside Emacs are not affected."
  :global t
  :lighter " AITrk"
  (if ai-tracks-magit-mode
      (progn
        (add-hook 'git-commit-post-finish-hook #'ai-tracks-after-commit)
        (add-hook 'magit-post-commit-hook      #'ai-tracks-after-commit))
    (remove-hook 'git-commit-post-finish-hook  #'ai-tracks-after-commit)
    (remove-hook 'magit-post-commit-hook       #'ai-tracks-after-commit)))

(provide 'ai-tracks)

;;; ai-tracks.el ends here

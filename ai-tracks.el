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

(defun ai-tracks--capture-session (session-id cwd source)
  "Trigger the org-roam capture for a new AI track.
SESSION-ID is the Claude Code session UUID.  CWD and SOURCE come from
the SessionStart JSON payload; either may be nil."
  (unless (bound-and-true-p org-roam-gt-mode)
    (org-roam-gt-mode 1))
  (let* ((now       (current-time))
         (title     (format-time-string "Track %Y-%m-%d %a %H:%M" now))
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
                     (ai-tracks--escape-capture cwd)
                     (ai-tracks--escape-capture source)
                     (ai-tracks--escape-capture started)))
         (org-roam-capture-templates
          `(("t" "AI Track"
             entry ,body
             :target (node+headline nil "AI Tracks")
             :empty-lines 1))))
    (org-roam-capture-)))

;;;###autoload
(defun ai-tracks-session-start (json-file)
  "Handler for the Claude Code SessionStart hook.
JSON-FILE is a path to the JSON payload the hook wrote to disk.
The file is read, parsed, and deleted; then the org-roam capture UI
is opened for the user to pick a node and describe the session."
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
      (ai-tracks--capture-session session-id cwd source))))

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
Scans the track's subtree for level-4 Recap headings and returns the
newest :CLAUDE-RECAPPED: property.  If no recap exists yet, returns
the track's :CLAUDE-STARTED: property.  Signals a user-error if the
track is not found or has no :CLAUDE-STARTED:."
  (let ((marker (ai-tracks--track-marker session-id))
        (latest nil))
    (org-with-point-at marker
      (org-map-entries
       (lambda ()
         (when-let* ((ts (org-entry-get (point) "CLAUDE-RECAPPED")))
           (when (or (not latest) (string> ts latest))
             (setq latest ts))))
       nil 'tree))
    (or latest
        (org-entry-get marker "CLAUDE-STARTED")
        (user-error "ai-tracks: no :CLAUDE-STARTED: property on track for %s"
                    session-id))))

(defun ai-tracks--recap-format-section (heading items)
  "Return a string for one level-5 recap section with HEADING and ITEMS.
Empty when ITEMS is nil or empty."
  (if (and items (listp items) (> (length items) 0))
      (concat (format "***** %s\n" heading)
              (mapconcat (lambda (item) (format "- %s\n" item)) items ""))
    ""))

(defun ai-tracks-recap-add (session-id json-file)
  "Append a Recap heading with sub-sections under the track for SESSION-ID.
JSON-FILE is a path to a JSON object with keys files, decisions, open,
next, each mapping to an array of short strings.  Missing or empty
sections are omitted.  The file is read and deleted."
  (let* ((marker (ai-tracks--track-marker session-id))
         (payload (unwind-protect
                      (with-temp-buffer
                        (insert-file-contents json-file)
                        (json-parse-buffer
                         :object-type 'alist
                         :array-type 'list
                         :null-object nil))
                    (ignore-errors (delete-file json-file))))
         (now   (current-time))
         (title (format-time-string "Recap %Y-%m-%d %a %H:%M" now))
         (ts    (format-time-string "[%Y-%m-%d %a %H:%M]" now))
         (sections '((files     . "Files touched")
                     (decisions . "Decisions")
                     (open      . "Open threads")
                     (next      . "Next"))))
    (org-with-point-at marker
      (goto-char (save-excursion (org-end-of-subtree t t)))
      (unless (bolp) (insert "\n"))
      (insert (format "**** %s\n:PROPERTIES:\n:CLAUDE-RECAPPED: %s\n:END:\n"
                      title ts))
      ;; Summary bullets are the Recap heading's own body text: a
      ;; narrative list of what was accomplished, above the per-topic
      ;; level-5 sections below.
      (let ((summary (alist-get 'summary payload)))
        (when (and summary (listp summary) (> (length summary) 0))
          (dolist (item summary)
            (insert (format "- %s\n" item)))))
      (dolist (section sections)
        (insert (ai-tracks--recap-format-section
                 (cdr section)
                 (alist-get (car section) payload))))
      (save-buffer))
    ts))

;;;; Point of Interest

(defvar ai-tracks-poi-categories
  '("Surprise" "Event" "Decision" "Observation" "Other")
  "Categories offered when creating a POI via `ai-tracks-poi-add'.")

(defun ai-tracks-poi-add (session-id)
  "Insert a level-4 POI heading under the track for SESSION-ID.
Prompts the user for a category from `ai-tracks-poi-categories'
via `completing-read', writes :TRACK-CATEGORY: and :CLAUDE-POI:
into the drawer, switches to the org file's buffer, and positions
point immediately after the drawer so the user can type the body."
  (let* ((marker (ai-tracks--track-marker session-id))
         (category (completing-read
                    "POI category: "
                    ai-tracks-poi-categories
                    nil t))
         (now (current-time))
         (title (format-time-string "POI %Y-%m-%d %a %H:%M" now))
         (ts (format-time-string "[%Y-%m-%d %a %H:%M]" now)))
    (switch-to-buffer (marker-buffer marker))
    (goto-char (marker-position marker))
    (goto-char (save-excursion (org-end-of-subtree t t)))
    (unless (bolp) (insert "\n"))
    (insert (format "**** %s\n:PROPERTIES:\n:TRACK-CATEGORY: %s\n:CLAUDE-POI: %s\n:END:\n"
                    title category ts))
    (org-reveal)
    (save-buffer)
    ts))

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
          :author  (magit-git-string "log" "-1" "--pretty=%aN" "HEAD")
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
             (let ((cwd (cdr (assoc "CLAUDE-CWD"
                                    (org-roam-node-properties node)))))
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
               "**** Commit %s — %s\n:PROPERTIES:\n:CLAUDE-COMMIT: %s\n:COMMIT-SHA: %s\n:COMMIT-AUTHOR: %s\n:END:\n"
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

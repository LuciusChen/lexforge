;;; lexforge.el --- Vocabulary learning system for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: lexforge
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (llm "0.12") (fsrs "0.1"))
;; Keywords: vocabulary, learning, education, spaced-repetition
;; URL: https://github.com/example/lexforge

;;; Commentary:

;; lexforge is a vocabulary learning system for Emacs.
;;
;; Features:
;; - Capture words from any buffer with context
;; - AI-powered word analysis (definitions, examples, etymology)
;; - FSRS-based spaced repetition scheduling
;; - Focus on specific meanings (e.g., rare usage of common words)
;; - Dedicated learning interface
;; - Essay generation for contextual learning
;; - Text-to-speech support
;;
;; Data flow:
;; 1. Capture: word → Org file (basic entry)
;; 2. AI analysis (lexforge-enrich) → Org file (formatted content)
;; 3. Build (lexforge-build) → Parse Org → SQLite (for learning)
;; 4. Learn: read from SQLite, update FSRS state
;; 5. Reorganize: use org-refile to move words between files
;; 6. Sync: lexforge-sync updates group_name/word in SQLite based on Org (by vocab_id)
;;
;; File structure:
;;   lexforge-words-directory/
;;   ├── default.org    ← default group
;;   ├── gre.org        ← "gre" group
;;   ├── daily.org      ← "daily" group
;;   └── lexforge.db    ← SQLite database (created by lexforge-build)
;;
;; Quick start:
;;   (require 'lexforge)
;;   (setq lexforge-words-directory "~/lexforge/")
;;   (lexforge-ai-setup-openrouter "your-api-key")  ; or other provider
;;   (global-set-key (kbd "C-c v") 'lexforge-command-map)
;;
;; Workflow:
;;   1. C-c v c  - Capture word to Org
;;   2. C-c v r  - Run AI analysis (updates Org)
;;   3. M-x lexforge-build - Build SQLite from Org files
;;   4. C-c v l  - Start learning session
;;
;; Commands (bind lexforge-command-map to your prefix):
;;   c - Capture word (to default.org)
;;   C - Capture word (select group/file)
;;   f - Capture with focus (specific meaning)
;;   r - Refresh: analyze all unprocessed words
;;   R - Refresh single word (select from list)
;;   b - Build SQLite from Org files
;;   l - Start learning session
;;   G - Open vocabulary list
;;   o - Open group org file
;;   d - Open vocab directory
;;   y - Sync group changes from Org to database

;;; Code:

(require 'cl-lib)
(require 'sqlite)
(require 'llm)
(require 'fsrs)
(require 'json)
(require 'org)
(require 'org-element)

(declare-function speed-type-region "speed-type")
(declare-function pdf-view-active-region-text "pdf-view")

;;;; Customization Groups

(defgroup lexforge nil
  "Vocabulary learning system."
  :prefix "lexforge-"
  :group 'applications)

(defgroup lexforge-ai nil
  "AI settings for lexforge."
  :group 'lexforge)

(defgroup lexforge-srs nil
  "SRS settings for lexforge."
  :group 'lexforge)

;;;; Custom Variables

(defcustom lexforge-words-directory (expand-file-name "lexforge/" user-emacs-directory)
  "Directory containing vocabulary org files.
Each .org file represents a group (filename without extension = group name)."
  :type 'directory
  :group 'lexforge)

(defcustom lexforge-db-file (expand-file-name "lexforge/lexforge.db" user-emacs-directory)
  "Path to the SQLite database file."
  :type 'file
  :group 'lexforge)

(defcustom lexforge-ai-provider nil
  "LLM provider for lexforge.
If nil, will try to auto-detect from environment variables."
  :type 'sexp
  :group 'lexforge-ai)

(defcustom lexforge-ai-max-tokens 2048
  "Maximum tokens for AI response."
  :type 'integer
  :group 'lexforge-ai)

(defcustom lexforge-srs-desired-retention 0.9
  "Target retention rate (0.0 to 1.0)."
  :type 'float
  :group 'lexforge-srs)

(defcustom lexforge-srs-learning-steps '(1 10)
  "Learning steps in minutes."
  :type '(repeat integer)
  :group 'lexforge-srs)

(defcustom lexforge-srs-relearning-steps '(10)
  "Relearning steps in minutes."
  :type '(repeat integer)
  :group 'lexforge-srs)

(defcustom lexforge-learn-new-cards-per-day 20
  "Maximum new cards per day."
  :type 'integer
  :group 'lexforge)

(defcustom lexforge-essay-default-length 150
  "Default essay length in words."
  :type 'integer
  :group 'lexforge)

(defcustom lexforge-essay-default-difficulty "intermediate"
  "Default difficulty level."
  :type 'string
  :group 'lexforge)

(defcustom lexforge-essay-word-count 5
  "Default number of words for essay."
  :type 'integer
  :group 'lexforge)

(defcustom lexforge-lexdb-adapter nil
  "The lexdb adapter ID to use for lookups.
If nil, uses the current adapter in lexdb.
Lexdb integration is automatically enabled when lexdb is loaded."
  :type '(choice (const :tag "Use current adapter" nil)
                 (string :tag "Adapter ID"))
  :group 'lexforge)

;;;; Prompt Templates

(defcustom lexforge-prompt-word-analysis
  "Analyze \"%s\". Return JSON:
{\"lemma\":\"base form\",\"phonetic\":\"IPA of lemma\",\"definitions\":[{\"pos\":\"v.\",\"meaning\":\"Chinese\",\"meaning_en\":\"English\"}],\"examples\":[{\"en\":\"sentence\",\"zh\":\"translation\"}]}
Note: phonetic should be for the lemma (base form), not the input word.
1-2 defs, 1 example. JSON only."
  "Prompt for word analysis."
  :type 'string
  :group 'lexforge-ai)

(defcustom lexforge-prompt-phrase-analysis
  "Analyze the phrase \"%s\". Return JSON:
{\"lemma\":\"%s\",\"definitions\":[{\"pos\":\"phrase\",\"meaning\":\"Chinese meaning\",\"meaning_en\":\"English meaning\"}],\"examples\":[{\"en\":\"example sentence\",\"zh\":\"translation\"}]}
This is a phrase/idiom, no phonetic needed. 1-2 defs, 1 example. JSON only."
  "Prompt for phrase analysis (no phonetic/roots)."
  :type 'string
  :group 'lexforge-ai)

(defcustom lexforge-prompt-essay-generation
  "Write a short essay using the following words:

Words: %s
Length: around %d words
Difficulty: %s
Topic: %s

Requirements: Use all words naturally with complete structure.

Return JSON:
{\"title\": \"title\", \"content\": \"content\", \"translation\": \"Chinese translation\", \"word_usage\": [{\"word\": \"word\", \"sentence\": \"sentence\", \"explanation\": \"explanation\"}]}"
  "Prompt for essay generation."
  :type 'string
  :group 'lexforge-ai)

(defcustom lexforge-prompt-select-senses
  "The word \"%s\" has multiple dictionary senses and examples.

Context (if available): %s

Dictionary data:
%s

Based on the context (or common usage if no context), select the most appropriate sense(s) and example(s).

Return JSON:
{\"lemma\":\"%s\",\"phonetic\":\"%s\",\"definitions\":[{\"pos\":\"v.\",\"meaning\":\"Chinese meaning\",\"meaning_en\":\"English meaning\"}],\"examples\":[{\"en\":\"example sentence\",\"zh\":\"Chinese translation\"}]}

Requirements:
- Select 1-2 most relevant definitions based on context
- Select 1 most relevant example
- If Chinese translation already exists in dictionary data, use it directly
- If no Chinese translation exists, translate following the '中文重生场' style below
- Keep original English meanings from dictionary
- JSON only, no explanation

=== 中文重生场 Translation Style ===
英文进入此场即死，中文从其养分中生。

【遗忘之律】忘记英文的句法和语序，只记住它要说的事。
【重生之律】如果你是中国作者，面对中国读者，你会怎么讲？
【地道之律】用中文自己的韵律：四字短语的节奏感、口语的亲切感、成语俗语的画面感。

检验标准：读完后，读者会说「写得真好」而不是「翻译得真好」。
真实之锚：术语规范标注，如：大语言模型（LLM）"
  "Prompt for selecting senses from lexdb data."
  :type 'string
  :group 'lexforge-ai)

(defvar lexforge-essay-difficulty-levels
  '(("elementary" . "Elementary")
    ("intermediate" . "Intermediate")
    ("advanced" . "Advanced")
    ("native" . "Native")))

(defvar lexforge-essay-topics
  '("Daily life" "Technology" "Nature" "Relationships" "Work" "Travel" "Culture" "Random"))

;;;; ============================================================
;;;; Database Module
;;;; ============================================================

(defvar lexforge-db--connection nil "Database connection.")
(defvar lexforge-db--migrated nil "Whether database migrations have been applied.")

(defun lexforge-db--ensure-connection ()
  "Ensure database connection."
  ;; If file doesn't exist, recreate connection
  (when (and lexforge-db--connection
             (not (file-exists-p lexforge-db-file)))
    (ignore-errors (sqlite-close lexforge-db--connection))
    (setq lexforge-db--connection nil
          lexforge-db--migrated nil))
  ;; Establish connection
  (unless (and lexforge-db--connection (sqlitep lexforge-db--connection))
    ;; Ensure directory exists
    (let ((dir (file-name-directory lexforge-db-file)))
      (unless (file-exists-p dir)
        (make-directory dir t)))
    (setq lexforge-db--connection (sqlite-open lexforge-db-file)
          lexforge-db--migrated nil)
    (lexforge-db--init-tables))
  ;; Always run migrations (idempotent)
  (unless lexforge-db--migrated
    (lexforge-db--run-migrations)
    (setq lexforge-db--migrated t))
  lexforge-db--connection)

(defun lexforge-db-close ()
  "Close database."
  (when (and lexforge-db--connection (sqlitep lexforge-db--connection))
    (sqlite-close lexforge-db--connection)
    (setq lexforge-db--connection nil
          lexforge-db--migrated nil)))

;;;###autoload
(defun lexforge-db-reset ()
  "Reset database (delete and rebuild from Org files)."
  (interactive)
  (when (yes-or-no-p "Reset database? Learning progress will be lost!")
    (lexforge-db-close)
    (when (file-exists-p lexforge-db-file)
      (delete-file lexforge-db-file))
    (lexforge-build)
    (message "Database reset complete")))

(defun lexforge-db--column-exists-p (table column)
  "Check if COLUMN exists in TABLE."
  (let ((db lexforge-db--connection))
    (cl-some (lambda (row) (string= (nth 1 row) column))
             (sqlite-select db (format "PRAGMA table_info(%s)" table)))))

(defun lexforge-db--run-migrations ()
  "Run database migrations."
  (let ((db lexforge-db--connection))
    ;; Migration 1: add step column for FSRS 6.0
    (unless (lexforge-db--column-exists-p "words" "step")
      (sqlite-execute db "ALTER TABLE words ADD COLUMN step INTEGER DEFAULT 0")
      (message "lexforge: added step column"))
    ;; Migration 2: migrate from group_id to group_name
    (when (lexforge-db--column-exists-p "words" "group_id")
      (unless (lexforge-db--column-exists-p "words" "group_name")
        (sqlite-execute db "ALTER TABLE words ADD COLUMN group_name TEXT")
        (condition-case nil
            (sqlite-execute db "UPDATE words SET group_name = (SELECT name FROM groups WHERE groups.id = words.group_id)")
          (error nil))
        (message "lexforge: migrated to group_name")))
    ;; Migration 3: add vocab_id column
    (unless (lexforge-db--column-exists-p "words" "vocab_id")
      (sqlite-execute db "ALTER TABLE words ADD COLUMN vocab_id TEXT")
      (sqlite-execute db "CREATE UNIQUE INDEX IF NOT EXISTS idx_words_vocab_id ON words(vocab_id)")
      (message "lexforge: added vocab_id column"))))

(defun lexforge-db--init-tables ()
  "Initialize tables."
  (let ((db lexforge-db--connection))
    ;; Words table - vocab_id links to org entry
    (sqlite-execute db "
CREATE TABLE IF NOT EXISTS words (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT UNIQUE NOT NULL,
    word TEXT NOT NULL,
    vocab_id TEXT UNIQUE,
    group_name TEXT,
    phonetic TEXT,
    focus TEXT,
    due TEXT NOT NULL DEFAULT (datetime('now')),
    stability REAL NOT NULL DEFAULT 0.0,
    difficulty REAL NOT NULL DEFAULT 0.0,
    state TEXT NOT NULL DEFAULT 'new',
    step INTEGER DEFAULT 0,
    last_review TEXT,
    reps INTEGER NOT NULL DEFAULT 0,
    lapses INTEGER NOT NULL DEFAULT 0,
    suspended INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
)")
    (sqlite-execute db "
CREATE TABLE IF NOT EXISTS definitions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT UNIQUE NOT NULL,
    word_id INTEGER NOT NULL,
    part_of_speech TEXT,
    meaning TEXT NOT NULL,
    meaning_en TEXT,
    is_common INTEGER DEFAULT 1,
    FOREIGN KEY (word_id) REFERENCES words(id) ON DELETE CASCADE
)")
    (sqlite-execute db "
CREATE TABLE IF NOT EXISTS examples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT UNIQUE NOT NULL,
    word_id INTEGER NOT NULL,
    sentence TEXT NOT NULL,
    translation TEXT,
    FOREIGN KEY (word_id) REFERENCES words(id) ON DELETE CASCADE
)")
    (sqlite-execute db "
CREATE TABLE IF NOT EXISTS word_relations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT UNIQUE NOT NULL,
    word_id INTEGER NOT NULL,
    related_word TEXT NOT NULL,
    relation_type TEXT,
    FOREIGN KEY (word_id) REFERENCES words(id) ON DELETE CASCADE
)")
    (sqlite-execute db "
CREATE TABLE IF NOT EXISTS review_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT UNIQUE NOT NULL,
    word_id INTEGER NOT NULL,
    rating TEXT NOT NULL,
    reviewed_at TEXT NOT NULL,
    FOREIGN KEY (word_id) REFERENCES words(id) ON DELETE CASCADE
)")
    (sqlite-execute db "CREATE INDEX IF NOT EXISTS idx_words_due ON words(due)")
    (sqlite-execute db "CREATE INDEX IF NOT EXISTS idx_words_word ON words(word)")
    (sqlite-execute db "CREATE INDEX IF NOT EXISTS idx_words_group ON words(group_name)")))

(defun lexforge-db--generate-uuid ()
  "Generate a UUID v4."
  (format "%04x%04x-%04x-%04x-%04x-%04x%04x%04x"
          (random 65536) (random 65536)
          (random 65536)
          (logior (logand (random 65536) #x0fff) #x4000)
          (logior (logand (random 65536) #x3fff) #x8000)
          (random 65536) (random 65536) (random 65536)))

;; Word operations
(defun lexforge-db-get-word (word)
  "Get word record."
  (let ((db (lexforge-db--ensure-connection)))
    (car (sqlite-select db "SELECT id, word, phonetic, focus, due, stability, difficulty, state, last_review, reps, lapses, suspended FROM words WHERE word = ?" (list word)))))

(defun lexforge-db-get-word-by-id (id)
  "Get word by ID."
  (let ((db (lexforge-db--ensure-connection)))
    (car (sqlite-select db "SELECT id, word, phonetic, focus, due, stability, difficulty, state, last_review, reps, lapses, suspended FROM words WHERE id = ?" (list id)))))

(defun lexforge-db-update-fsrs (word-id fsrs-data)
  "Update FSRS fields for WORD-ID."
  (let* ((db (lexforge-db--ensure-connection))
         (now (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
         (due (or (alist-get 'due fsrs-data) now))
         (stability (let ((s (alist-get 'stability fsrs-data)))
                      (if (and s (numberp s) (> s 0)) s 1.0)))
         (difficulty (let ((d (alist-get 'difficulty fsrs-data)))
                       (if (and d (numberp d)) d 5.0)))
         (state (or (alist-get 'state fsrs-data) "learning"))
         (step (let ((st (alist-get 'step fsrs-data)))
                 (if (and st (integerp st)) st 0)))
         (last-review (or (alist-get 'last_review fsrs-data) now))
         (reps (or (alist-get 'reps fsrs-data) 0))
         (lapses (or (alist-get 'lapses fsrs-data) 0)))
    (sqlite-execute db
      "UPDATE words SET due = ?, stability = ?, difficulty = ?, state = ?, step = ?, last_review = ?, reps = ?, lapses = ?, updated_at = datetime('now') WHERE id = ?"
      (list due stability difficulty state step last-review reps lapses word-id))))

(defun lexforge-db-get-due-words (&optional limit)
  "Get due words."
  (let ((db (lexforge-db--ensure-connection))
        (sql "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE due <= datetime('now') AND suspended = 0 ORDER BY due ASC"))
    (when limit (setq sql (concat sql (format " LIMIT %d" limit))))
    (sqlite-select db sql)))

(defun lexforge-db-get-new-words (&optional limit)
  "Get new words."
  (let ((db (lexforge-db--ensure-connection))
        (sql "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE state = 'new' AND suspended = 0 ORDER BY created_at ASC"))
    (when limit (setq sql (concat sql (format " LIMIT %d" limit))))
    (sqlite-select db sql)))

(defun lexforge-db-get-learning-words ()
  "Get learning words."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-select db "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE state IN ('learning', 'relearning') AND due <= datetime('now') AND suspended = 0 ORDER BY due ASC")))

(defun lexforge-db-get-all-learnable-words (&optional limit)
  "Get all words for learning (ignoring due time)."
  (let ((db (lexforge-db--ensure-connection))
        (sql "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE suspended = 0 ORDER BY CASE state WHEN 'new' THEN 0 WHEN 'learning' THEN 1 WHEN 'relearning' THEN 2 ELSE 3 END, due ASC"))
    (when limit (setq sql (concat sql (format " LIMIT %d" limit))))
    (sqlite-select db sql)))

;; Definition operations
(defun lexforge-db-get-definitions (word-id)
  "Get definitions."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-select db "SELECT id, part_of_speech, meaning, meaning_en, is_common FROM definitions WHERE word_id = ? ORDER BY is_common DESC" (list word-id))))

;; Example operations
(defun lexforge-db-get-examples (word-id)
  "Get examples."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-select db "SELECT id, sentence, translation FROM examples WHERE word_id = ?" (list word-id))))

;; Relation operations
(defun lexforge-db-get-relations (word-id)
  "Get relations."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-select db "SELECT id, related_word, relation_type FROM word_relations WHERE word_id = ?" (list word-id))))

;; Review log
(defun lexforge-db-add-review-log (word-id rating)
  "Add review log."
  (let ((db (lexforge-db--ensure-connection))
        (uuid (lexforge-db--generate-uuid)))
    (sqlite-execute db "INSERT INTO review_logs (uuid, word_id, rating, reviewed_at) VALUES (?, ?, ?, datetime('now'))"
                    (list uuid word-id (symbol-name rating)))))

;; Utilities
(defun lexforge-db-get-all-words ()
  "Get all words."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-select db "SELECT id, word, phonetic, state FROM words ORDER BY word")))

(defun lexforge-db-get-word-count ()
  "Get word count."
  (let ((db (lexforge-db--ensure-connection)))
    (caar (sqlite-select db "SELECT COUNT(*) FROM words"))))

(defun lexforge-db-get-random-words (&optional count)
  "Get random words."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-select db (format "SELECT id, word, phonetic, state FROM words ORDER BY RANDOM() LIMIT %d" (or count 10)))))

(defun lexforge-db-get-review-stats-today ()
  "Get today's stats."
  (let ((db (lexforge-db--ensure-connection)))
    (car (sqlite-select db "SELECT COUNT(*), SUM(CASE WHEN rating = 'again' THEN 1 ELSE 0 END), SUM(CASE WHEN rating = 'hard' THEN 1 ELSE 0 END), SUM(CASE WHEN rating = 'good' THEN 1 ELSE 0 END), SUM(CASE WHEN rating = 'easy' THEN 1 ELSE 0 END) FROM review_logs WHERE date(reviewed_at) = date('now')"))))

(defun lexforge-db--delete-word-by-id (word-id)
  "Delete word by WORD-ID."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-execute db "DELETE FROM words WHERE id = ?" (list word-id))))

(defun lexforge-db--update-word-text (word-id new-word)
  "Update word text to NEW-WORD for WORD-ID."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-execute db "UPDATE words SET word = ?, updated_at = datetime('now') WHERE id = ?" (list new-word word-id))))

(defun lexforge-db-set-word-focus (word-id focus)
  "Set FOCUS for WORD-ID."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-execute db "UPDATE words SET focus = ?, updated_at = datetime('now') WHERE id = ?" (list focus word-id))))

(defun lexforge-db-get-word-focus (word-id)
  "Get focus for WORD-ID."
  (let ((db (lexforge-db--ensure-connection)))
    (caar (sqlite-select db "SELECT focus FROM words WHERE id = ?" (list word-id)))))

;;; Group operations (based on org files in lexforge-words-directory)
(defun lexforge-db-get-all-groups ()
  "Get all groups from org files in lexforge-words-directory."
  (lexforge-org--ensure-directory)
  (let ((files (directory-files lexforge-words-directory nil "\\.org$")))
    (mapcar (lambda (f) (file-name-sans-extension f)) files)))

(defun lexforge-db-set-word-group (word-id group-name)
  "Set GROUP-NAME for WORD-ID."
  (let ((db (lexforge-db--ensure-connection)))
    (sqlite-execute db "UPDATE words SET group_name = ?, updated_at = datetime('now') WHERE id = ?"
                    (list group-name word-id))))

(defun lexforge-db-get-word-group (word-id)
  "Get group name for WORD-ID."
  (let ((db (lexforge-db--ensure-connection)))
    (caar (sqlite-select db "SELECT group_name FROM words WHERE id = ?" (list word-id)))))

(defun lexforge-db-get-due-words-by-group (group-name &optional limit)
  "Get due words in GROUP-NAME."
  (let* ((db (lexforge-db--ensure-connection))
         (sql (if group-name
                  "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE due <= datetime('now') AND suspended = 0 AND group_name = ? ORDER BY due ASC"
                "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE due <= datetime('now') AND suspended = 0 AND group_name IS NULL ORDER BY due ASC")))
    (when limit (setq sql (concat sql (format " LIMIT %d" limit))))
    (if group-name
        (sqlite-select db sql (list group-name))
      (sqlite-select db sql))))

(defun lexforge-db-get-new-words-by-group (group-name &optional limit)
  "Get new words in GROUP-NAME."
  (let* ((db (lexforge-db--ensure-connection))
         (sql (if group-name
                  "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE state = 'new' AND suspended = 0 AND group_name = ? ORDER BY created_at ASC"
                "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE state = 'new' AND suspended = 0 AND group_name IS NULL ORDER BY created_at ASC")))
    (when limit (setq sql (concat sql (format " LIMIT %d" limit))))
    (if group-name
        (sqlite-select db sql (list group-name))
      (sqlite-select db sql))))

(defun lexforge-db-get-learning-words-by-group (group-name)
  "Get learning words in GROUP-NAME."
  (let ((db (lexforge-db--ensure-connection)))
    (if group-name
        (sqlite-select db "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE state IN ('learning', 'relearning') AND due <= datetime('now') AND suspended = 0 AND group_name = ? ORDER BY due ASC" (list group-name))
      (sqlite-select db "SELECT id, word, phonetic, due, stability, difficulty, state, step, last_review, reps, lapses FROM words WHERE state IN ('learning', 'relearning') AND due <= datetime('now') AND suspended = 0 AND group_name IS NULL ORDER BY due ASC"))))

(defun lexforge-db-get-group-word-count (group-name)
  "Get word count in GROUP-NAME."
  (let ((db (lexforge-db--ensure-connection)))
    (if group-name
        (caar (sqlite-select db "SELECT COUNT(*) FROM words WHERE group_name = ?" (list group-name)))
      (caar (sqlite-select db "SELECT COUNT(*) FROM words WHERE group_name IS NULL")))))

;;;; ============================================================
;;;; Lexdb Integration Module
;;;; ============================================================
;; Integration with lexdb for dictionary lookups.
;; When lexforge-use-lexdb is non-nil, we query lexdb first,
;; then use AI to select appropriate senses based on context.

(declare-function lexdb-lookup "lexdb")
(declare-function lexdb-entry-headword "lexdb")
(declare-function lexdb-entry-senses "lexdb")
(declare-function lexdb-entry-pronunciations "lexdb")
(declare-function lexdb-sense-definition "lexdb")
(declare-function lexdb-sense-examples "lexdb")
(declare-function lexdb-sense-labels "lexdb")
(declare-function lexdb-example-text "lexdb")
(declare-function lexdb-pronunciation-ipa "lexdb")

(defun lexforge-lexdb--available-p ()
  "Check if lexdb is available.
Returns non-nil when lexdb package is loaded."
  (featurep 'lexdb))

(defun lexforge-lexdb-lookup (word)
  "Lookup WORD in lexdb, return entries or nil."
  (when (lexforge-lexdb--available-p)
    (condition-case nil
        (lexdb-lookup word lexforge-lexdb-adapter)
      (error nil))))

(defun lexforge-lexdb--format-entry-for-ai (entries)
  "Format lexdb ENTRIES as text for AI prompt."
  (when entries
    (with-temp-buffer
      (let ((entry-num 0))
        (dolist (entry entries)
          (cl-incf entry-num)
          (insert (format "\n=== Entry %d: %s ===\n"
                          entry-num
                          (or (lexdb-entry-headword entry) "?")))
          ;; Pronunciations
          (when-let ((prons (lexdb-entry-pronunciations entry)))
            (dolist (pron prons)
              (when-let ((ipa (lexdb-pronunciation-ipa pron)))
                (insert (format "Pronunciation: %s\n" ipa)))))
          ;; Senses
          (let ((sense-num 0))
            (dolist (sense (lexdb-entry-senses entry))
              (cl-incf sense-num)
              (insert (format "\nSense %d:\n" sense-num))
              ;; Labels (POS, etc.)
              (when-let ((labels (lexdb-sense-labels sense)))
                (insert (format "  Labels: %s\n"
                                (mapconcat #'identity labels ", "))))
              ;; Definition
              (when-let ((def (lexdb-sense-definition sense)))
                (insert (format "  Definition: %s\n" def)))
              ;; Examples
              (when-let ((examples (lexdb-sense-examples sense)))
                (insert "  Examples:\n")
                (dolist (ex examples)
                  (when-let ((text (lexdb-example-text ex)))
                    (insert (format "    - %s\n" text)))))))))
      (buffer-string))))

(defun lexforge-lexdb--get-first-phonetic (entries)
  "Get first available IPA from ENTRIES."
  (catch 'found
    (dolist (entry entries)
      (when-let ((prons (lexdb-entry-pronunciations entry)))
        (dolist (pron prons)
          (when-let ((ipa (lexdb-pronunciation-ipa pron)))
            (throw 'found ipa)))))
    nil))

;;;; ============================================================
;;;; AI Module
;;;; ============================================================

(defun lexforge-ai--get-provider ()
  "Get LLM provider, or nil if not configured."
  (or lexforge-ai-provider
      (cond
       ((getenv "ANTHROPIC_API_KEY")
        (require 'llm-claude)
        (make-llm-claude :key (getenv "ANTHROPIC_API_KEY")))
       ((getenv "OPENAI_API_KEY")
        (require 'llm-openai)
        (make-llm-openai :key (getenv "OPENAI_API_KEY")))
       (t nil))))

(defun lexforge-ai-setup-anthropic (api-key &optional model)
  "Setup Anthropic."
  (require 'llm-claude)
  (setq lexforge-ai-provider
        (make-llm-claude :key api-key :chat-model (or model "claude-sonnet-4-5"))))

(defun lexforge-ai-setup-openai (api-key &optional model)
  "Setup OpenAI."
  (require 'llm-openai)
  (setq lexforge-ai-provider
        (make-llm-openai :key api-key :chat-model (or model "gpt-4o"))))

(defun lexforge-ai-setup-openrouter (api-key &optional model)
  "Setup OpenRouter.
MODEL defaults to \"anthropic/claude-3.5-sonnet\".
See https://openrouter.ai/models for available models."
  (require 'llm-openai)
  (setq lexforge-ai-provider
        (make-llm-openai-compatible
         :key api-key
         :url "https://openrouter.ai/api/v1"
         :chat-model (or model "anthropic/claude-3.5-sonnet"))))

(defun lexforge-ai-setup-ollama (&optional model)
  "Setup Ollama."
  (require 'llm-ollama)
  (setq lexforge-ai-provider
        (make-llm-ollama :chat-model (or model "llama3.2"))))

(defun lexforge-ai--clean-json (response)
  "Extract JSON from RESPONSE, removing markdown code blocks."
  (let ((s response))
    ;; Remove markdown code block markers
    (setq s (replace-regexp-in-string "```json" "" s))
    (setq s (replace-regexp-in-string "```" "" s))
    ;; Find the first {
    (when (string-match "{" s)
      (setq s (substring s (match-beginning 0))))
    ;; Do not truncate! Let fix function handle truncated JSON
    (string-trim s)))

(defun lexforge-ai--vectors-to-lists (obj)
  "Recursively convert vectors to lists in OBJ."
  (cond
   ((vectorp obj)
    (mapcar #'lexforge-ai--vectors-to-lists (append obj nil)))
   ((listp obj)
    (mapcar (lambda (item)
              (if (consp item)
                  (cons (car item) (lexforge-ai--vectors-to-lists (cdr item)))
                item))
            obj))
   (t obj)))

(defun lexforge-ai-request (prompt callback &optional error-callback)
  "Send PROMPT async, call CALLBACK."
  (let ((provider (lexforge-ai--get-provider)))
    (if provider
        (let ((chat-prompt (llm-make-chat-prompt prompt)))
          ;; Set max-tokens (different llm versions may vary)
          (when (fboundp 'llm-chat-prompt-max-tokens)
            (setf (llm-chat-prompt-max-tokens chat-prompt) lexforge-ai-max-tokens))
          (llm-chat-async
           provider
           chat-prompt
           callback
           (lambda (err-type err-msg)
             (if error-callback
                 (funcall error-callback (format "%s: %s" err-type err-msg))
               (message "lexforge-ai error: %s" err-msg)))))
      (when error-callback
        (funcall error-callback "No LLM provider configured")))))

(defun lexforge-ai--try-fix-json (s)
  "Try to fix truncated JSON string S."
  ;; 1. Handle truncated strings: find the last complete structure
  (let ((in-string nil)
        (escaped nil)
        (last-complete-pos 0)
        (i 0)
        (len (length s)))
    (while (< i len)
      (let ((c (aref s i)))
        (cond
         (escaped (setq escaped nil))
         ((= c ?\\) (setq escaped t))
         ((= c ?\")
          (setq in-string (not in-string))
          (unless in-string
            ;; String just ended
            (setq last-complete-pos (1+ i))))
         ((and (not in-string) (memq c '(?\] ?\} ?,)))
          (setq last-complete-pos (1+ i)))))
      (cl-incf i))
    ;; If truncated in middle of string, rollback
    (when in-string
      (setq s (substring s 0 last-complete-pos))))
  ;; 2. Remove incomplete trailing content (comma or whitespace)
  (setq s (replace-regexp-in-string "[,\\s\n\r]+$" "" s))
  ;; 3. Count and close brackets
  (let ((braces 0) (brackets 0))
    (dotimes (i (length s))
      (let ((c (aref s i)))
        (cond ((= c ?\{) (cl-incf braces))
              ((= c ?\}) (cl-decf braces))
              ((= c ?\[) (cl-incf brackets))
              ((= c ?\]) (cl-decf brackets)))))
    ;; Close ] first, then }
    (dotimes (_ brackets) (setq s (concat s "]")))
    (dotimes (_ braces) (setq s (concat s "}"))))
  s)

(defun lexforge--is-phrase-p (text)
  "Return non-nil if TEXT is a phrase (contains spaces)."
  (and text (string-match-p " " text)))

(defun lexforge-ai-analyze-word (word callback &optional error-callback context)
  "Analyze WORD (or phrase).
If `lexforge-use-lexdb' is non-nil and lexdb has data for WORD,
use AI to select appropriate senses from lexdb data.
Otherwise, generate definitions using AI directly.
CONTEXT is optional context for better sense selection."
  (let ((lexdb-entries (lexforge-lexdb-lookup word)))
    (if lexdb-entries
        ;; Use lexdb data + AI selection
        (lexforge-ai--select-senses word lexdb-entries context callback error-callback)
      ;; Fallback to AI generation
      (lexforge-ai--generate-analysis word callback error-callback))))

(defun lexforge-ai--generate-analysis (word callback &optional error-callback)
  "Generate analysis for WORD using AI directly (original behavior)."
  (let ((prompt (if (lexforge--is-phrase-p word)
                    (format lexforge-prompt-phrase-analysis word word)
                  (format lexforge-prompt-word-analysis word))))
    (lexforge-ai-request
     prompt
     (lambda (response)
       (let* ((cleaned (lexforge-ai--clean-json response))
              (parsed nil))
         ;; Try direct parsing first
         (condition-case nil
             (setq parsed (json-read-from-string cleaned))
           (error
            ;; Try to fix truncated JSON
            (let ((fixed (lexforge-ai--try-fix-json cleaned)))
              (message "Attempting to fix truncated JSON (length: %d -> %d)"
                       (length cleaned) (length fixed))
              (condition-case err
                  (setq parsed (json-read-from-string fixed))
                (error
                 (message "Raw (last 200): ...%s"
                          (substring cleaned (max 0 (- (length cleaned) 200))))
                 (message "Fixed (last 200): ...%s"
                          (substring fixed (max 0 (- (length fixed) 200))))
                 (when error-callback
                   (funcall error-callback (format "Parse error: %s" err))))))))
         (when parsed
           ;; Convert vectors to lists (JSON arrays parse as vectors)
           (setq parsed (lexforge-ai--vectors-to-lists parsed))
           (funcall callback parsed))))
     error-callback)))

(defun lexforge-ai--select-senses (word entries context callback &optional error-callback)
  "Use AI to select appropriate senses from lexdb ENTRIES for WORD.
CONTEXT provides the usage context for better selection."
  (let* ((dict-data (lexforge-lexdb--format-entry-for-ai entries))
         (phonetic (or (lexforge-lexdb--get-first-phonetic entries) ""))
         (context-str (or context "(no context provided)"))
         (prompt (format lexforge-prompt-select-senses
                         word context-str dict-data word phonetic)))
    (message "Using lexdb data for '%s'" word)
    (lexforge-ai-request
     prompt
     (lambda (response)
       (let* ((cleaned (lexforge-ai--clean-json response))
              (parsed nil))
         (condition-case nil
             (setq parsed (json-read-from-string cleaned))
           (error
            (let ((fixed (lexforge-ai--try-fix-json cleaned)))
              (condition-case err
                  (setq parsed (json-read-from-string fixed))
                (error
                 (message "Parse error with lexdb selection: %s" err)
                 (when error-callback
                   (funcall error-callback (format "Parse error: %s" err))))))))
         (when parsed
           (setq parsed (lexforge-ai--vectors-to-lists parsed))
           (funcall callback parsed))))
     error-callback)))

(defun lexforge-ai-generate-essay (words length difficulty topic callback &optional error-callback)
  "Generate essay."
  (lexforge-ai-request
   (format lexforge-prompt-essay-generation (string-join words ", ") length difficulty topic)
   (lambda (response)
     (let* ((cleaned (lexforge-ai--clean-json response))
            (parsed nil))
       (condition-case nil
           (setq parsed (json-read-from-string cleaned))
         (error
          (condition-case err
              (setq parsed (json-read-from-string (lexforge-ai--try-fix-json cleaned)))
            (error
             (message "Raw response: %s" (substring response 0 (min 500 (length response))))
             (when error-callback
               (funcall error-callback (format "Parse error: %s" err)))))))
       (when parsed
         (setq parsed (lexforge-ai--vectors-to-lists parsed))
         (funcall callback parsed))))
   error-callback))

;;;; ============================================================
;;;; SRS Module (FSRS)
;;;; ============================================================

(defvar lexforge-srs--scheduler nil "FSRS scheduler.")

(defun lexforge-srs--minutes-to-timespans (minutes-list)
  "Convert MINUTES-LIST (list of integers) to FSRS timespan format."
  (mapcar (lambda (m) (list m :minute)) minutes-list))

(defun lexforge-srs--get-scheduler ()
  "Get scheduler."
  (unless lexforge-srs--scheduler
    (setq lexforge-srs--scheduler
          (fsrs-make-scheduler
           :desired-retention lexforge-srs-desired-retention
           :enable-fuzzing-p t
           :learning-steps (lexforge-srs--minutes-to-timespans lexforge-srs-learning-steps)
           :relearning-steps (lexforge-srs--minutes-to-timespans lexforge-srs-relearning-steps))))
  lexforge-srs--scheduler)

(defun lexforge-srs--alist-to-card (alist)
  "Convert ALIST to fsrs-card.
Note: reps and lapses are tracked in lexforge's SQLite, not in fsrs-card."
  (let ((card (fsrs-make-card)))
    (when-let ((v (alist-get 'due alist))) (setf (fsrs-card-due card) v))
    (when-let ((v (alist-get 'stability alist))) (setf (fsrs-card-stability card) v))
    (when-let ((v (alist-get 'difficulty alist))) (setf (fsrs-card-difficulty card) v))
    (when-let ((v (alist-get 'state alist)))
      (setf (fsrs-card-state card) (if (symbolp v) v (intern (concat ":" v)))))
    (when-let ((v (alist-get 'last_review alist))) (setf (fsrs-card-last-review card) v))
    (when-let ((v (alist-get 'step alist))) (setf (fsrs-card-step card) v))
    ;; reps and lapses are managed separately in lexforge's database
    card))

(defun lexforge-srs--card-to-alist (card)
  "Convert CARD to alist.
Ensures all values have safe defaults."
  (let ((due (ignore-errors (fsrs-card-due card)))
        (stability (ignore-errors (fsrs-card-stability card)))
        (difficulty (ignore-errors (fsrs-card-difficulty card)))
        (state (ignore-errors (fsrs-card-state card)))
        (last-review (ignore-errors (fsrs-card-last-review card)))
        (step (ignore-errors (fsrs-card-step card))))
    `((due . ,(or due (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))
      (stability . ,(if (and stability (numberp stability) (> stability 0)) stability 1.0))
      (difficulty . ,(if (and difficulty (numberp difficulty)) difficulty 5.0))
      (state . ,(lexforge-srs--state-to-string state))
      (last_review . ,(or last-review (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))
      (step . ,(if (and step (integerp step)) step 0)))))

(defun lexforge-srs--state-to-string (state)
  "Convert STATE to string for database storage."
  (cond
   ((null state) "new")
   ((stringp state) state)
   ((keywordp state) (substring (symbol-name state) 1))  ; :new -> "new"
   ((symbolp state) (symbol-name state))                  ; new -> "new"
   ((integerp state)                                      ; 0 -> "new", 1 -> "learning", etc.
    (pcase state
      (0 "new")
      (1 "learning")
      (2 "review")
      (3 "relearning")
      (_ "new")))
   (t "new")))

(defun lexforge-srs-review-card (card-data rating)
  "Review CARD-DATA with RATING.
Returns an alist with updated card state."
  (condition-case err
      (lexforge-srs--review-with-fsrs card-data rating)
    (error
     (message "FSRS error: %s, using fallback" err)
     (lexforge-srs--review-fallback card-data rating))))

(defun lexforge-srs--review-with-fsrs (card-data rating)
  "Review using FSRS library."
  (let* ((scheduler (lexforge-srs--get-scheduler))
         (card (lexforge-srs--alist-to-card card-data))
         (state (fsrs-card-state card))
         (now (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))
    ;; FSRS only accepts :learning, :review, :relearning
    (unless (memq state '(:learning :review :relearning))
      (setf (fsrs-card-state card) :learning)
      (setf (fsrs-card-step card) 0))
    ;; fsrs-scheduler-review-card returns (cl-values card review-log)
    (cl-multiple-value-bind (updated-card _review-log)
        (fsrs-scheduler-review-card scheduler card rating now)
      (lexforge-srs--card-to-alist updated-card))))

(defun lexforge-srs--review-fallback (card-data rating)
  "Simple fallback SRS when FSRS fails."
  (let* ((now (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
         (old-stability (or (alist-get 'stability card-data) 1.0))
         (old-difficulty (or (alist-get 'difficulty card-data) 5.0))
         ;; Simple interval calculation (minutes)
         (interval-minutes
          (pcase rating
            (:again 1)      ; 1 minute
            (:hard 10)      ; 10 minutes
            (:good (* old-stability 1440))  ; stability days
            (:easy (* old-stability 2880)))) ; stability * 2 days
         ;; Limit max interval to 365 days
         (interval-minutes (min interval-minutes (* 365 1440)))
         (due-time (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                       (time-add nil (* interval-minutes 60)) t))
         ;; Update stability and difficulty
         (new-stability
          (pcase rating
            (:again (max 0.1 (* old-stability 0.5)))
            (:hard old-stability)
            (:good (min 365.0 (* old-stability 2.0)))
            (:easy (min 365.0 (* old-stability 3.0)))))
         (new-difficulty
          (pcase rating
            (:again (min 10.0 (+ old-difficulty 0.5)))
            (:hard (min 10.0 (+ old-difficulty 0.2)))
            (:good old-difficulty)
            (:easy (max 1.0 (- old-difficulty 0.2)))))
         (new-state
          (pcase rating
            (:again "learning")
            (_ "review"))))
    `((due . ,due-time)
      (stability . ,new-stability)
      (difficulty . ,new-difficulty)
      (state . ,new-state)
      (last_review . ,now)
      (step . 0))))

(defun lexforge-srs-new-card ()
  "Create new card state with initial reps and lapses."
  (let* ((card (fsrs-make-card))
         (card-alist (lexforge-srs--card-to-alist card)))
    ;; Force new card state to "new" (fsrs-make-card may return other states)
    (setf (alist-get 'state card-alist) "new")
    ;; Add reps and lapses (tracked by lexforge, not fsrs)
    (setf (alist-get 'reps card-alist) 0)
    (setf (alist-get 'lapses card-alist) 0)
    card-alist))

(defun lexforge-srs-state-name (state)
  "Get name for STATE."
  (pcase state
    ((or "new" :new) "New")
    ((or "learning" :learning) "Learning")
    ((or "review" :review) "Review")
    ((or "relearning" :relearning) "Relearning")
    (_ "Unknown")))

;;;; ============================================================
;;;; Org Module (Source of Truth for static content)
;;;; ============================================================
;; Each .org file in lexforge-words-directory represents a group.
;; Each level-1 heading is a word with:
;;   :VOCAB_ID: - stable unique identifier
;;   :PHONETIC: - pronunciation
;;   :FOCUS:    - specific meaning to focus on (optional)
;; Content under heading contains definitions, examples, etc.

(defun lexforge-org--ensure-directory ()
  "Ensure vocab words directory exists."
  (unless (file-exists-p lexforge-words-directory)
    (make-directory lexforge-words-directory t)))

(defun lexforge-org--group-file (group)
  "Get org file path for GROUP."
  (expand-file-name (concat group ".org") lexforge-words-directory))

(defun lexforge-org--ensure-group-file (group)
  "Ensure org file for GROUP exists."
  (lexforge-org--ensure-directory)
  (let ((file (lexforge-org--group-file group)))
    (unless (file-exists-p file)
      (with-temp-file file
        (insert (format "#+TITLE: %s\n#+STARTUP: overview\n\n" group))))
    file))

(defun lexforge-org--with-group-file (group func)
  "Execute FUNC in GROUP's org file."
  (let* ((file (lexforge-org--ensure-group-file group))
         (was-open (get-file-buffer file)))
    (with-current-buffer (find-file-noselect file)
      (save-excursion (funcall func))
      (save-buffer)
      (unless was-open (kill-buffer)))))

(defun lexforge-org--generate-lexforge-id ()
  "Generate a unique VOCAB_ID."
  (format "%s-%04x"
          (format-time-string "%Y%m%d%H%M%S")
          (random 65536)))

(defun lexforge-org-add-word (word &optional context group focus)
  "Add WORD entry with CONTEXT to GROUP file, optionally with FOCUS.
Generates a unique VOCAB_ID for the word."
  (let ((target-group (or group "default"))
        (lexforge-id (lexforge-org--generate-lexforge-id)))
    (lexforge-org--with-group-file
     target-group
     (lambda ()
       (goto-char (point-max))
       ;; Ensure exactly one blank line before new entry
       (skip-chars-backward "\n")
       (delete-region (point) (point-max))
       (insert "\n\n")
       (insert (format "* %s\n" word))
       (insert ":PROPERTIES:\n")
       (insert (format ":VOCAB_ID: %s\n" lexforge-id))
       (insert (format ":ADDED_AT: %s\n" (format-time-string "[%Y-%m-%d %a]")))
       (when focus (insert (format ":FOCUS: %s\n" focus)))
       (insert ":END:\n")
       (when (and context (not (string-empty-p (string-trim context))))
         (let ((clean-context (lexforge-org--clean-context context)))
           (insert "\n#+BEGIN_QUOTE\n")
           (insert clean-context)
           (insert "\n#+END_QUOTE\n")))))
    lexforge-id))

(defun lexforge-org--clean-context (context)
  "Clean CONTEXT string for safe insertion into org file."
  (let ((s context))
    ;; Truncate to 300 chars
    (setq s (substring s 0 (min 300 (length s))))
    ;; Replace newlines with spaces
    (setq s (replace-regexp-in-string "[\n\r\t]+" " " s))
    ;; Remove chars that may interfere with org parsing
    (setq s (replace-regexp-in-string "#\\+" "" s))
    ;; Trim whitespace
    (string-trim s)))

(defun lexforge-org-update-word-data (word data group)
  "Update WORD entry with AI DATA in GROUP file.
Stores all data in org format (properties + content).
Preserves PROPERTIES and context quote (BEGIN_QUOTE...END_QUOTE)."
  (lexforge-org--with-group-file
   group
   (lambda ()
     (goto-char (point-min))
     (when (re-search-forward (format "^\\* %s$" (regexp-quote word)) nil t)
       (let* ((heading-start (line-beginning-position))
              (entry-end (save-excursion
                           (if (re-search-forward "^\\* " nil t)
                               (line-beginning-position)
                             (point-max))))
              content-start)
         ;; Update PHONETIC property (only for single words, not phrases)
         (when-let ((phonetic (alist-get 'phonetic data)))
           (unless (lexforge--is-phrase-p word)
             (save-excursion
               (goto-char heading-start)
               (when (re-search-forward ":PROPERTIES:" entry-end t)
                 (let ((prop-end (save-excursion
                                   (re-search-forward ":END:" entry-end t)
                                   (point))))
                   (if (re-search-forward "^:PHONETIC:" prop-end t)
                       (progn (kill-line) (insert (format " %s" phonetic)))
                     (goto-char prop-end)
                     (forward-line -1)
                     (end-of-line)
                     (insert (format "\n:PHONETIC: %s" phonetic))))))))
         ;; Find content start (after PROPERTIES and optional BEGIN_QUOTE block)
         (goto-char heading-start)
         (forward-line 1)
         ;; Skip PROPERTIES block
         (when (looking-at ":PROPERTIES:")
           (re-search-forward "^:END:" entry-end t)
           (forward-line 1))
         ;; Skip empty lines
         (while (and (< (point) entry-end) (looking-at "^$"))
           (forward-line 1))
         ;; Skip BEGIN_QUOTE block if present
         (when (looking-at "#\\+BEGIN_QUOTE")
           (when (re-search-forward "^#\\+END_QUOTE" entry-end t)
             (forward-line 1)))
         ;; Skip empty lines after quote
         (while (and (< (point) entry-end) (looking-at "^$"))
           (forward-line 1))
         ;; Now we're at the start of content to replace
         (setq content-start (point))
         ;; Delete old content (definitions, examples, etc.)
         (delete-region content-start entry-end)
         ;; Insert new content
         (insert "\n")
         ;; Definitions
         (when-let ((defs (alist-get 'definitions data)))
           (insert "** Definitions\n")
           (dolist (d defs)
             (insert (format "- %s %s"
                             (or (alist-get 'pos d) "")
                             (alist-get 'meaning d)))
             (when-let ((en (alist-get 'meaning_en d)))
               (insert (format " (%s)" en)))
             (insert "\n"))
           (insert "\n"))
         ;; Examples
         (when-let ((exs (alist-get 'examples data)))
           (insert "** Examples\n")
           (dolist (e exs)
             (insert (format "- %s\n" (alist-get 'en e)))
             (when-let ((zh (alist-get 'zh e)))
               (insert (format "  /%s/\n" zh))))
           (insert "\n")))))))

(defun lexforge-org--parse-word-entry (headline)
  "Parse a word HEADLINE element into an alist."
  (let* ((word (org-element-property :raw-value headline))
         (lexforge-id (org-element-property :VOCAB_ID headline))
         (phonetic (org-element-property :PHONETIC headline))
         (focus (org-element-property :FOCUS headline))
         (begin (org-element-property :contents-begin headline))
         (end (org-element-property :contents-end headline))
         definitions examples)
    ;; Parse content for definitions and examples
    (when (and begin end)
      (save-excursion
        (goto-char begin)
        ;; Parse definitions section
        (when (re-search-forward "^\\*\\* \\(Definitions\\|Definitions\\)" end t)
          (let ((section-end (or (save-excursion
                                   (when (re-search-forward "^\\*\\* " end t)
                                     (line-beginning-position)))
                                 end)))
            (while (re-search-forward "^- \\([^ ]+\\) \\(.+\\)$" section-end t)
              (push `((pos . ,(match-string 1))
                      (meaning . ,(match-string 2)))
                    definitions))))
        ;; Parse examples section
        (goto-char begin)
        (when (re-search-forward "^\\*\\* \\(Examples\\|Examples\\)" end t)
          (let ((section-end (or (save-excursion
                                   (when (re-search-forward "^\\*\\* " end t)
                                     (line-beginning-position)))
                                 end)))
            (while (re-search-forward "^- \\(.+\\)$" section-end t)
              (let ((en (match-string 1))
                    (zh nil))
                (when (looking-at "\n  /\\(.+\\)/")
                  (setq zh (match-string 1)))
                (push `((en . ,en) (zh . ,zh)) examples)))))))
    `((word . ,word)
      (vocab_id . ,lexforge-id)
      (phonetic . ,phonetic)
      (focus . ,focus)
      (definitions . ,(nreverse definitions))
      (examples . ,(nreverse examples)))))

(defun lexforge-org--parse-file (file)
  "Parse org FILE and return list of word entries."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (let (words)
        (org-element-map (org-element-parse-buffer) 'headline
          (lambda (hl)
            (when (= 1 (org-element-property :level hl))
              (push (lexforge-org--parse-word-entry hl) words))))
        (nreverse words)))))

(defun lexforge-org--parse-all-files ()
  "Parse all org files and return alist of (group . words-list)."
  (lexforge-org--ensure-directory)
  (let ((files (directory-files lexforge-words-directory t "\\.org$"))
        result)
    (dolist (file files)
      (let ((group (file-name-sans-extension (file-name-nondirectory file)))
            (words (lexforge-org--parse-file file)))
        (push (cons group words) result)))
    result))

(defun lexforge-org-find-word (word)
  "Find WORD in all org files. Return (group . file) or nil."
  (lexforge-org--ensure-directory)
  (let ((files (directory-files lexforge-words-directory t "\\.org$")))
    (cl-loop for file in files
             for group = (file-name-sans-extension (file-name-nondirectory file))
             when (with-temp-buffer
                    (insert-file-contents file)
                    (re-search-forward (format "^\\* %s$" (regexp-quote word)) nil t))
             return (cons group file))))

(defun lexforge-org-find-by-id (lexforge-id)
  "Find word by VOCAB_ID. Return (group word file) or nil."
  (lexforge-org--ensure-directory)
  (let ((files (directory-files lexforge-words-directory t "\\.org$")))
    (cl-loop for file in files
             for group = (file-name-sans-extension (file-name-nondirectory file))
             do (with-temp-buffer
                  (insert-file-contents file)
                  (org-mode)
                  (goto-char (point-min))
                  (when (re-search-forward (format ":VOCAB_ID: %s" (regexp-quote lexforge-id)) nil t)
                    (org-back-to-heading t)
                    (cl-return (list group
                                     (org-element-property :raw-value (org-element-at-point))
                                     file)))))))

(defun lexforge-org-goto-word (word)
  "Open org file and goto WORD heading."
  (when-let ((found (lexforge-org-find-word word)))
    (find-file (cdr found))
    (goto-char (point-min))
    (re-search-forward (format "^\\* %s$" (regexp-quote word)) nil t)
    (org-back-to-heading t)
    t))

(defun lexforge-org--delete-word (word &optional group)
  "Delete WORD entry. If GROUP is nil, search all files."
  (if group
      (lexforge-org--with-group-file
       group
       (lambda ()
         (goto-char (point-min))
         (when (re-search-forward (format "^\\* %s$" (regexp-quote word)) nil t)
           (org-back-to-heading t)
           (org-cut-subtree))))
    (when-let ((found (lexforge-org-find-word word)))
      (lexforge-org--delete-word word (car found)))))

(defun lexforge-org--rename-word (old-word new-word &optional group)
  "Rename OLD-WORD to NEW-WORD. If GROUP is nil, search all files."
  (if group
      (lexforge-org--with-group-file
       group
       (lambda ()
         (goto-char (point-min))
         (when (re-search-forward (format "^\\* %s$" (regexp-quote old-word)) nil t)
           (replace-match (format "* %s" new-word)))))
    (when-let ((found (lexforge-org-find-word old-word)))
      (lexforge-org--rename-word old-word new-word (car found)))))

(defun lexforge-org-get-lexforge-id (word &optional group)
  "Get VOCAB_ID for WORD. If GROUP is nil, search all files."
  (if group
      (let ((file (lexforge-org--group-file group)))
        (when (file-exists-p file)
          (with-temp-buffer
            (insert-file-contents file)
            (org-mode)
            (goto-char (point-min))
            (when (re-search-forward (format "^\\* %s$" (regexp-quote word)) nil t)
              (org-element-property :VOCAB_ID (org-element-at-point))))))
    (when-let ((found (lexforge-org-find-word word)))
      (lexforge-org-get-lexforge-id word (car found)))))

(defun lexforge-org-get-context (word &optional group)
  "Get context (BEGIN_QUOTE content) for WORD. If GROUP is nil, search all files."
  (if group
      (let ((file (lexforge-org--group-file group)))
        (when (file-exists-p file)
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (when (re-search-forward (format "^\\* %s$" (regexp-quote word)) nil t)
              (let ((entry-end (save-excursion
                                 (if (re-search-forward "^\\* " nil t)
                                     (line-beginning-position)
                                   (point-max)))))
                (when (re-search-forward "#\\+BEGIN_QUOTE" entry-end t)
                  (forward-line 1)
                  (let ((start (point)))
                    (when (re-search-forward "#\\+END_QUOTE" entry-end t)
                      (string-trim (buffer-substring-no-properties
                                    start (line-beginning-position)))))))))))
    (when-let ((found (lexforge-org-find-word word)))
      (lexforge-org-get-context word (car found)))))

;;;###autoload
(defun lexforge-build ()
  "Build SQLite database from org files.
Parses all org files and populates SQLite with static content.
Preserves existing FSRS state for known vocab_ids."
  (interactive)
  (lexforge-org--ensure-directory)
  (let* ((org-data (lexforge-org--parse-all-files))
         (db (lexforge-db--ensure-connection))
         ;; Get existing FSRS states by vocab_id
         (existing-fsrs (make-hash-table :test 'equal))
         (added 0) (updated 0))
    ;; Save existing FSRS states
    (dolist (row (sqlite-select db "SELECT vocab_id, due, stability, difficulty, state, step, last_review, reps, lapses, suspended FROM words WHERE vocab_id IS NOT NULL"))
      (puthash (nth 0 row) (cdr row) existing-fsrs))
    ;; Clear and rebuild static content
    (sqlite-execute db "DELETE FROM words")
    (sqlite-execute db "DELETE FROM definitions")
    (sqlite-execute db "DELETE FROM examples")
    ;; Process each group
    (dolist (group-data org-data)
      (let ((group (car group-data))
            (words (cdr group-data)))
        (dolist (entry words)
          (let* ((word (alist-get 'word entry))
                 (lexforge-id (alist-get 'vocab_id entry))
                 (phonetic (alist-get 'phonetic entry))
                 (focus (alist-get 'focus entry))
                 (defs (alist-get 'definitions entry))
                 (exs (alist-get 'examples entry))
                 (existing (gethash lexforge-id existing-fsrs))
                 word-id)
            ;; Insert word
            (if existing
                (progn
                  ;; Restore with existing FSRS state
                  (sqlite-execute db
                    "INSERT INTO words (uuid, word, vocab_id, group_name, phonetic, focus, due, stability, difficulty, state, step, last_review, reps, lapses, suspended) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                    (list (lexforge-db--generate-uuid) word lexforge-id group phonetic focus
                          (nth 0 existing) (nth 1 existing) (nth 2 existing) (nth 3 existing)
                          (nth 4 existing) (nth 5 existing) (nth 6 existing) (nth 7 existing) (nth 8 existing)))
                  (cl-incf updated))
              ;; New word with fresh FSRS state
              (let ((new-card (lexforge-srs-new-card)))
                (sqlite-execute db
                  "INSERT INTO words (uuid, word, vocab_id, group_name, phonetic, focus, due, stability, difficulty, state, step, reps, lapses) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                  (list (lexforge-db--generate-uuid) word lexforge-id group phonetic focus
                        (alist-get 'due new-card) (alist-get 'stability new-card)
                        (alist-get 'difficulty new-card) (alist-get 'state new-card)
                        (alist-get 'step new-card) 0 0)))
              (cl-incf added))
            ;; Get word id
            (setq word-id (caar (sqlite-select db "SELECT id FROM words WHERE vocab_id = ?" (list lexforge-id))))
            ;; Insert definitions
            (dolist (d defs)
              (sqlite-execute db
                "INSERT INTO definitions (uuid, word_id, part_of_speech, meaning) VALUES (?, ?, ?, ?)"
                (list (lexforge-db--generate-uuid) word-id (alist-get 'pos d) (alist-get 'meaning d))))
            ;; Insert examples
            (dolist (e exs)
              (sqlite-execute db
                "INSERT INTO examples (uuid, word_id, sentence, translation) VALUES (?, ?, ?, ?)"
                (list (lexforge-db--generate-uuid) word-id (alist-get 'en e) (alist-get 'zh e))))))))
    (message "Build complete: added %d, updated %d" added updated)))

;;;###autoload
(defun lexforge-sync ()
  "Synchronize from org files to database using vocab_id.
Updates group_name and word text if changed.
Words deleted from org files will also be deleted from database."
  (interactive)
  (lexforge-org--ensure-directory)
  (let* ((org-data (lexforge-org--parse-all-files))  ; ((group . (entry ...)) ...)
         (db (lexforge-db--ensure-connection))
         (db-words (sqlite-select db "SELECT id, word, vocab_id, group_name FROM words"))
         ;; Hash: vocab_id -> (group . word) from org files
         (org-lexforge-map (make-hash-table :test 'equal))
         (moved 0) (renamed 0) (removed 0))
    ;; Build hash from org files
    (dolist (group-data org-data)
      (let ((group (car group-data))
            (entries (cdr group-data)))
        (dolist (entry entries)
          (when-let ((vid (alist-get 'vocab_id entry)))
            (puthash vid (cons group (alist-get 'word entry)) org-lexforge-map)))))
    ;; Process each word in database
    (dolist (row db-words)
      (let* ((id (nth 0 row))
             (db-word (nth 1 row))
             (lexforge-id (nth 2 row))
             (db-group (nth 3 row))
             (org-entry (gethash lexforge-id org-lexforge-map)))
        (cond
         ;; vocab_id not in any org file → delete from db
         ((not org-entry)
          (lexforge-db--delete-word-by-id id)
          (cl-incf removed))
         (t
          (let ((org-group (car org-entry))
                (org-word (cdr org-entry)))
            ;; Word text changed (renamed in org) → update
            (when (and org-word (not (equal db-word org-word)))
              (lexforge-db--update-word-text id org-word)
              (cl-incf renamed))
            ;; Group changed → update
            (when (not (equal db-group org-group))
              (lexforge-db-set-word-group id org-group)
              (cl-incf moved)))))))
    ;; Report
    (if (and (= moved 0) (= renamed 0) (= removed 0))
        (message "Sync complete, no changes")
      (message "Sync complete: moved %d, renamed %d, deleted %d" moved renamed removed))))

;;;###autoload
(defun lexforge-open-group (group)
  "Open org file for GROUP."
  (interactive
   (list (completing-read "Open group: " (lexforge-db-get-all-groups) nil t)))
  (find-file (lexforge-org--ensure-group-file group)))

;;;###autoload
(defun lexforge-open-directory ()
  "Open vocab words directory in dired."
  (interactive)
  (lexforge-org--ensure-directory)
  (dired lexforge-words-directory))

;;;; ============================================================
;;;; TTS Module
;;;; ============================================================

(defun lexforge-tts--get-command ()
  "Get TTS command."
  (cond
   ((eq system-type 'darwin) "say '%s'")
   ((executable-find "espeak") "espeak '%s'")
   ((executable-find "espeak-ng") "espeak-ng '%s'")
   (t (error "No TTS available"))))

(defun lexforge-tts-speak (text)
  "Speak TEXT."
  (interactive "sText: ")
  (let ((cmd (format (lexforge-tts--get-command)
                     (replace-regexp-in-string "'" "'\\''" text))))
    (start-process-shell-command "lexforge-tts" nil cmd)))

(defun lexforge-tts-stop ()
  "Stop TTS."
  (interactive)
  (when-let ((proc (get-process "lexforge-tts")))
    (delete-process proc)))

;;;; ============================================================
;;;; Speed-type Integration
;;;; ============================================================

(defun lexforge--speed-type-text (text)
  "Start speed-type session with TEXT.
Creates a temporary buffer with TEXT and uses speed-type-region."
  (let ((buf (get-buffer-create "*Lexforge Typing*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert text)
      (goto-char (point-min))
      (set-mark (point-max))
      (speed-type-region (point-min) (point-max)))))

;;;; ============================================================
;;;; Learn Module
;;;; ============================================================

(defvar lexforge-learn--buffer "*Lexforge Learn*")
(defvar-local lexforge-learn--word nil)
(defvar-local lexforge-learn--word-id nil)
(defvar-local lexforge-learn--card-data nil)
(defvar-local lexforge-learn--queue nil)
(defvar-local lexforge-learn--showing-answer nil)
(defvar-local lexforge-learn--stats nil)
(defvar-local lexforge-learn--group nil)

(defvar lexforge-learn-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'lexforge-learn-show-answer)
    (define-key map (kbd "RET") #'lexforge-learn-show-answer)
    (define-key map (kbd "<return>") #'lexforge-learn-show-answer)
    (define-key map (kbd "1") #'lexforge-learn-rate-again)
    (define-key map (kbd "2") #'lexforge-learn-rate-hard)
    (define-key map (kbd "3") #'lexforge-learn-rate-good)
    (define-key map (kbd "4") #'lexforge-learn-rate-easy)
    (define-key map (kbd "p") #'lexforge-learn-play-word)
    (define-key map (kbd "s") #'lexforge-learn-play-sentence)
    (define-key map (kbd "t") #'lexforge-learn-type-examples)
    (define-key map (kbd "q") #'lexforge-learn-quit)
    map))

;; Override meow/evil modal editor keymaps
(defvar-local lexforge-learn--active nil "Non-nil when lexforge-learn-mode keymap should be active.")
(defvar lexforge-learn--emulation-alist nil "Alist for `emulation-mode-map-alists'.")
(setq lexforge-learn--emulation-alist `((lexforge-learn--active . ,lexforge-learn-mode-map)))
(add-to-list 'emulation-mode-map-alists 'lexforge-learn--emulation-alist)

(define-derived-mode lexforge-learn-mode special-mode "LexLearn"
  "Vocabulary learning mode."
  (setq buffer-read-only t truncate-lines nil word-wrap t)
  ;; Activate emulation keymap (override meow SPC)
  (setq lexforge-learn--active t))

;;;###autoload
(defun lexforge-learn (&optional group)
  "Start learning session for GROUP (or select interactively).
Only shows words that are due for review."
  (interactive)
  (let* ((groups (lexforge-db-get-all-groups))
         (group-names (cons "All" groups))
         (selected (or group
                       (completing-read "Select group: " group-names nil t)))
         (use-group (unless (string= selected "All") selected)))
    (let ((buf (get-buffer-create lexforge-learn--buffer)))
      (with-current-buffer buf
        (lexforge-learn-mode)
        (setq lexforge-learn--group use-group)
        (setq lexforge-learn--queue
              (if use-group
                  (append (lexforge-db-get-learning-words-by-group use-group)
                          (lexforge-db-get-due-words-by-group use-group)
                          (lexforge-db-get-new-words-by-group use-group lexforge-learn-new-cards-per-day))
                (append (lexforge-db-get-learning-words)
                        (lexforge-db-get-due-words)
                        (lexforge-db-get-new-words lexforge-learn-new-cards-per-day))))
        (setq lexforge-learn--stats '((reviewed . 0) (again . 0) (hard . 0) (good . 0) (easy . 0)))
        (if lexforge-learn--queue
            (lexforge-learn--next-card)
          (lexforge-learn--show-empty)))
      (switch-to-buffer buf))))

;;;###autoload
(defun lexforge-learn-all (&optional limit)
  "Start learning session with ALL words (ignoring due time).
Use this to review words before their scheduled time.
With prefix arg, limit to that many words."
  (interactive "P")
  (let ((buf (get-buffer-create lexforge-learn--buffer))
        (max-words (or limit 50)))
    (with-current-buffer buf
      (lexforge-learn-mode)
      (setq lexforge-learn--group nil)
      (setq lexforge-learn--queue (lexforge-db-get-all-learnable-words max-words))
      (setq lexforge-learn--stats '((reviewed . 0) (again . 0) (hard . 0) (good . 0) (easy . 0)))
      (if lexforge-learn--queue
          (progn
            (message "Loaded %d words (ignoring due time)" (length lexforge-learn--queue))
            (lexforge-learn--next-card))
        (lexforge-learn--show-empty)))
    (switch-to-buffer buf)))

(defun lexforge-learn--next-card ()
  "Show next card."
  (if (null lexforge-learn--queue)
      (lexforge-learn--show-complete)
    (let* ((rec (pop lexforge-learn--queue)))
      ;; Fields: id(0), word(1), phonetic(2), due(3), stability(4), difficulty(5),
      ;;         state(6), step(7), last_review(8), reps(9), lapses(10)
      (setq lexforge-learn--word-id (nth 0 rec)
            lexforge-learn--word (nth 1 rec)
            lexforge-learn--card-data `((due . ,(nth 3 rec)) (stability . ,(nth 4 rec))
                                     (difficulty . ,(nth 5 rec)) (state . ,(nth 6 rec))
                                     (step . ,(nth 7 rec))
                                     (last_review . ,(nth 8 rec)) (reps . ,(nth 9 rec))
                                     (lapses . ,(nth 10 rec)))
            lexforge-learn--showing-answer nil)
      (lexforge-learn--render-question))))

(defun lexforge-learn--render-question ()
  "Render question."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "━━━━━━━━━━━━━━━━ [%s] ━━━━━━━━━━━━━━━━\n"
                                (or lexforge-learn--group "All")) 'face 'shadow))
    (insert (propertize (format "  %s\n" lexforge-learn--word) 'face '(:height 2.0 :weight bold)))
    (insert (propertize (format "  [%s]\n" (lexforge-srs-state-name (alist-get 'state lexforge-learn--card-data))) 'face 'shadow))
    (insert (propertize "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n" 'face 'shadow))
    (insert (propertize "  [SPC] Show answer  [p] Play  [t] Type\n" 'face 'font-lock-comment-face))
    (goto-char (point-min))))

(defun lexforge-learn-show-answer ()
  "Show answer."
  (interactive)
  (when (and lexforge-learn--word (not lexforge-learn--showing-answer))
    (setq lexforge-learn--showing-answer t)
    (lexforge-learn--render-answer)))

(defun lexforge--pos-face (pos)
  "Get face for part of speech POS.
Uses smaller font to distinguish from definition text."
  (let ((color (cond
                ((string-match-p "v\\." pos) "#8b7bb5")      ; soft purple
                ((string-match-p "n\\." pos) "#6b8cae")      ; soft blue
                ((string-match-p "adj\\." pos) "#5d9a8b")    ; soft teal
                ((string-match-p "adv\\." pos) "#b5936b")    ; soft orange
                ((string-match-p "prep\\." pos) "#8b7355")   ; soft brown
                ((string-match-p "phrase" pos) "#888888")    ; gray
                (t "#888888"))))
    `(:foreground ,color :height 0.85 :weight light)))

(defun lexforge-learn--render-answer ()
  "Render answer."
  (let ((inhibit-read-only t)
        (word-id lexforge-learn--word-id))
    (erase-buffer)
    (insert (propertize (format "━━━━━━━━━━━━━━━━ [%s] ━━━━━━━━━━━━━━━━\n"
                                (or lexforge-learn--group "All")) 'face 'shadow))
    ;; Word and phonetic
    (let ((rec (lexforge-db-get-word lexforge-learn--word)))
      (insert (propertize (format "  %s" lexforge-learn--word) 'face '(:height 2.0 :weight bold)))
      (when-let ((ph (nth 2 rec)))
        (insert (propertize (format "  %s" ph) 'face 'font-lock-string-face)))
      (insert "\n")
      ;; Focus (key meaning)
      (when-let ((focus (nth 3 rec)))
        (insert (propertize "  📌 " 'face '(:foreground "#c9a67a")))
        (insert (propertize focus 'face '(:foreground "#c9a67a" :weight bold)))
        (insert "\n")))
    (insert (propertize "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n" 'face 'shadow))
    ;; Definitions with POS coloring
    (let ((defs (lexforge-db-get-definitions word-id)))
      (when defs
        (insert (propertize "  Definitions:\n" 'face 'font-lock-keyword-face))
        (dolist (d defs)
          (let ((pos (or (nth 1 d) "")))
            (insert (format "    %s %s\n"
                            (propertize pos 'face (lexforge--pos-face pos))
                            (nth 2 d)))))
        (insert "\n")))
    ;; Examples
    (let ((exs (lexforge-db-get-examples word-id)))
      (when exs
        (insert (propertize "  Examples:\n" 'face 'font-lock-keyword-face))
        (dolist (e exs)
          (insert (format "    • %s\n" (nth 1 e)))
          (when (nth 2 e)
            (insert (propertize (format "      %s\n" (nth 2 e)) 'face 'font-lock-comment-face))))
        (insert "\n")))
    ;; Relations
    (let ((rels (lexforge-db-get-relations word-id)))
      (when rels
        (insert (propertize "  Related: " 'face 'font-lock-keyword-face))
        (insert (string-join (mapcar (lambda (r) (nth 1 r)) rels) ", "))
        (insert "\n\n")))
    ;; Rating
    (insert (propertize "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" 'face 'shadow))
    (insert "  ")
    (insert (propertize "[1]Again " 'face '(:foreground "#c97a7a")))   ; soft red
    (insert (propertize "[2]Hard " 'face '(:foreground "#c9a67a")))    ; soft orange
    (insert (propertize "[3]Good " 'face '(:foreground "#7ab57a")))    ; soft green
    (insert (propertize "[4]Easy" 'face '(:foreground "#7a9ec9")))     ; soft blue
    (insert "\n")
    (goto-char (point-min))))

(defun lexforge-learn--rate (rating)
  "Rate with RATING."
  (when (and lexforge-learn--showing-answer lexforge-learn--word-id)
    (let* ((updated (lexforge-srs-review-card lexforge-learn--card-data rating))
           ;; Manually track reps and lapses (not in fsrs-card anymore)
           (old-reps (or (alist-get 'reps lexforge-learn--card-data) 0))
           (old-lapses (or (alist-get 'lapses lexforge-learn--card-data) 0))
           (new-reps (1+ old-reps))
           (new-lapses (if (eq rating :again) (1+ old-lapses) old-lapses)))
      ;; Add reps and lapses to the updated alist
      (setf (alist-get 'reps updated) new-reps)
      (setf (alist-get 'lapses updated) new-lapses)
      (lexforge-db-update-fsrs lexforge-learn--word-id updated)
      (lexforge-db-add-review-log lexforge-learn--word-id rating)
      (cl-incf (alist-get 'reviewed lexforge-learn--stats))
      (cl-incf (alist-get (intern (substring (symbol-name rating) 1)) lexforge-learn--stats))
      (when (eq rating :again)
        (push (lexforge-db-get-word-by-id lexforge-learn--word-id) lexforge-learn--queue))
      (lexforge-learn--next-card))))

(defun lexforge-learn-rate-again () (interactive) (lexforge-learn--rate :again))
(defun lexforge-learn-rate-hard () (interactive) (lexforge-learn--rate :hard))
(defun lexforge-learn-rate-good () (interactive) (lexforge-learn--rate :good))
(defun lexforge-learn-rate-easy () (interactive) (lexforge-learn--rate :easy))

(defun lexforge-learn-play-word ()
  "Play word."
  (interactive)
  (when lexforge-learn--word (lexforge-tts-speak lexforge-learn--word)))

(defun lexforge-learn-play-sentence ()
  "Play sentence."
  (interactive)
  (when-let* ((exs (lexforge-db-get-examples lexforge-learn--word-id))
              (sent (nth 1 (car exs))))
    (lexforge-tts-speak sent)))

(defun lexforge-learn-type-examples ()
  "Practice typing examples for current word with speed-type."
  (interactive)
  (if (not (fboundp 'speed-type-region))
      (message "Please install speed-type package")
    (let* ((word-id lexforge-learn--word-id)
           (exs (when word-id (lexforge-db-get-examples word-id)))
           (sentences (mapcar (lambda (e) (nth 1 e)) exs)))
      (if sentences
          (lexforge--speed-type-text (string-join sentences "\n\n"))
        (message "No examples for this word")))))

(defun lexforge-learn-quit ()
  "Quit."
  (interactive)
  (lexforge-learn--show-summary)
  (when (y-or-n-p "Quit? ") (kill-buffer)))

(defun lexforge-learn--show-empty ()
  "Show empty."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (format "\n\n  🎉 No words to review! [Group: %s]\n\n  Press q to quit"
                    (or lexforge-learn--group "All")))))

(defun lexforge-learn--show-complete ()
  "Show complete."
  (lexforge-learn--show-summary)
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert "\n\n  ✅ Review complete!\n")))

(defun lexforge-learn--show-summary ()
  "Show summary."
  (let ((inhibit-read-only t)
        (s lexforge-learn--stats))
    (erase-buffer)
    (insert (format "\n  ━━━ Learning Stats [Group: %s] ━━━\n\n" (or lexforge-learn--group "All")))
    (insert (format "  Reviewed: %d\n" (alist-get 'reviewed s)))
    (insert (format "  Again: %d  Hard: %d  Good: %d  Easy: %d\n"
                    (alist-get 'again s) (alist-get 'hard s)
                    (alist-get 'good s) (alist-get 'easy s)))))

;;;; ============================================================
;;;; Essay Module
;;;; ============================================================

(defvar lexforge-essay--buffer "*Lexforge Essay*")
(defvar-local lexforge-essay--essay nil)
(defvar-local lexforge-essay--words nil)

(defvar lexforge-essay-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "t") #'lexforge-essay-typing)
    (define-key map (kbd "s") #'lexforge-essay-speak)
    (define-key map (kbd "r") #'lexforge-essay-regenerate)
    (define-key map (kbd "q") #'kill-buffer)
    map))

(define-derived-mode lexforge-essay-mode special-mode "LexEssay"
  "Essay mode."
  (setq buffer-read-only t truncate-lines nil word-wrap t))

;;;###autoload
(defun lexforge-generate-essay (&optional words)
  "Generate essay with WORDS."
  (interactive)
  (let* ((word-list (or words (lexforge-essay--select-words)))
         (length (read-number "Length (words): " lexforge-essay-default-length))
         (difficulty (completing-read "Difficulty: " (mapcar #'car lexforge-essay-difficulty-levels) nil t nil nil lexforge-essay-default-difficulty))
         (topic (completing-read "Topic: " lexforge-essay-topics nil nil nil nil "Random")))
    (message "Generating...")
    (lexforge-ai-generate-essay
     word-list length difficulty topic
     (lambda (data) (lexforge-essay--show data word-list))
     (lambda (err) (message "Generation failed: %s" err)))))

(defun lexforge-essay--select-words ()
  "Select words."
  (let ((all (lexforge-db-get-all-words)))
    (unless all (error "Word list is empty"))
    (let ((method (completing-read "Selection method: " '("Random" "Due" "Manual") nil t)))
      (pcase method
        ("Random" (mapcar (lambda (w) (nth 1 w)) (lexforge-db-get-random-words lexforge-essay-word-count)))
        ("Due" (let ((due (lexforge-db-get-due-words lexforge-essay-word-count)))
                   (if due (mapcar (lambda (w) (nth 1 w)) due) (error "No due words"))))
        ("Manual" (let (sel)
                  (while (y-or-n-p (format "Selected %d, continue? " (length sel)))
                    (push (completing-read "Word: " (mapcar (lambda (w) (nth 1 w)) all) nil t) sel))
                  (or sel (error "No words selected"))))))))

(defun lexforge-essay--show (data words)
  "Show essay DATA with WORDS."
  (let ((buf (get-buffer-create lexforge-essay--buffer)))
    (with-current-buffer buf
      (lexforge-essay-mode)
      (setq lexforge-essay--essay data lexforge-essay--words words)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "━━━ %s ━━━\n\n" (or (alist-get 'title data) "Essay")) 'face '(:weight bold)))
        (insert (format "Words: %s\n\n" (string-join words ", ")))
        (insert (or (alist-get 'content data) ""))
        (insert "\n\n")
        (when-let ((tr (alist-get 'translation data)))
          (insert (propertize (format "Translation:\n%s\n\n" tr) 'face 'font-lock-comment-face)))
        (insert "[t]Type [s]Speak [r]Regenerate [q]Quit\n")))
    (switch-to-buffer buf)))

(defun lexforge-essay-typing ()
  "Practice typing the generated essay with speed-type."
  (interactive)
  (cond
   ((not (fboundp 'speed-type-region))
    (message "Please install speed-type package"))
   ((not lexforge-essay--essay)
    (message "No essay generated. Press 'r' to generate one."))
   (t
    (let ((content (alist-get 'content lexforge-essay--essay)))
      (if (and content (not (string-empty-p content)))
          (lexforge--speed-type-text content)
        (message "Essay content is empty"))))))

(defun lexforge-essay-speak ()
  "Speak essay."
  (interactive)
  (when-let ((content (alist-get 'content lexforge-essay--essay)))
    (lexforge-tts-speak content)))

(defun lexforge-essay-regenerate ()
  "Regenerate."
  (interactive)
  (when lexforge-essay--words
    (lexforge-generate-essay lexforge-essay--words)))

;;;###autoload
(defun lexforge-type-examples (&optional count)
  "Practice typing with example sentences.
Uses COUNT random words (default 10) that have examples."
  (interactive "P")
  (if (not (fboundp 'speed-type-region))
      (message "Please install speed-type package")
    (let* ((n (or count 10))
           (db (lexforge-db--ensure-connection))
           ;; Get words that have examples
           (words-with-examples
            (sqlite-select db
              (format "SELECT DISTINCT w.id, w.word FROM words w
                       INNER JOIN examples e ON w.id = e.word_id
                       WHERE w.suspended = 0
                       ORDER BY RANDOM() LIMIT %d" n)))
           sentences)
      (if (not words-with-examples)
          (message "No examples available. Run lexforge-enrich first.")
        (dolist (w words-with-examples)
          (dolist (e (lexforge-db-get-examples (nth 0 w)))
            (push (nth 1 e) sentences)))
        (if sentences
            (lexforge--speed-type-text (string-join (nreverse sentences) "\n\n"))
          (message "No examples found"))))))

;;;; ============================================================
;;;; Lexforge List Mode (simplified interface)
;;;; ============================================================

(defvar lexforge-list--buffer "*Lexforge List*")
(defvar-local lexforge-list--group nil "Current group.")
(defvar-local lexforge-list--words nil "Current word list.")

(defvar lexforge-list-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Navigation
    (define-key map (kbd "n") #'lexforge-list-next)
    (define-key map (kbd "p") #'lexforge-list-prev)
    (define-key map (kbd "j") #'lexforge-list-next)
    (define-key map (kbd "k") #'lexforge-list-prev)
    ;; Actions
    (define-key map (kbd "RET") #'lexforge-list-view-word)
    (define-key map (kbd "o") #'lexforge-list-open-org)
    (define-key map (kbd "r") #'lexforge-list-refresh-word)
    (define-key map (kbd "s") #'lexforge-list-suspend-toggle)
    ;; Group switching
    (define-key map (kbd "g") #'lexforge-list-switch-group)
    (define-key map (kbd "G") #'lexforge-list-refresh)
    (define-key map (kbd "S") #'lexforge-list-sync)
    ;; Play
    (define-key map (kbd "P") #'lexforge-list-play-word)
    ;; Quit
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for lexforge-list-mode.")

(define-derived-mode lexforge-list-mode special-mode "LexList"
  "Major mode for viewing vocabulary list.

Edit words in org files, then use `S' to sync changes.

\\{lexforge-list-mode-map}"
  (setq buffer-read-only t)
  (setq truncate-lines t)
  (hl-line-mode 1))

;;;###autoload
(defun lexforge-list (&optional group)
  "Open vocabulary list for GROUP."
  (interactive)
  (let* ((groups (lexforge-db-get-all-groups))
         (group-names (cons "All" (cons "(Ungrouped)" groups)))
         (selected (or group
                       (completing-read "View group: " group-names nil t))))
    (let ((buf (get-buffer-create lexforge-list--buffer)))
      (with-current-buffer buf
        (lexforge-list-mode)
        (setq lexforge-list--group (unless (member selected '("All" "(Ungrouped)")) selected))
        (lexforge-list--refresh-contents selected))
      (switch-to-buffer buf))))

(defun lexforge-list--refresh-contents (group-filter)
  "Refresh buffer contents for GROUP-FILTER."
  (let ((inhibit-read-only t)
        (words (lexforge-list--get-words group-filter)))
    (setq lexforge-list--words words)
    (erase-buffer)
    ;; Header
    (insert (propertize (format "  Vocabulary List [%s]  (%d words)\n"
                                group-filter (length words))
                        'face '(:weight bold :height 1.2)))
    (insert (propertize "  RET:view o:edit-org s:suspend r:refresh-AI g:switch-group S:sync q:quit\n"
                        'face 'font-lock-comment-face))
    (insert (propertize "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                        'face 'shadow))
    ;; Word list
    (if (null words)
        (insert "\n  (empty)\n")
      (dolist (w words)
        (lexforge-list--insert-word-line w)))
    (goto-char (point-min))
    (forward-line 3)))

(defun lexforge-list--get-words (group-filter)
  "Get words for GROUP-FILTER."
  (let ((db (lexforge-db--ensure-connection)))
    (cond
     ((string= group-filter "All")
      (sqlite-select db "SELECT id, word, phonetic, state, suspended, group_name FROM words ORDER BY word"))
     ((string= group-filter "(Ungrouped)")
      (sqlite-select db "SELECT id, word, phonetic, state, suspended, NULL FROM words WHERE group_name IS NULL ORDER BY word"))
     (t
      (sqlite-select db "SELECT id, word, phonetic, state, suspended, group_name FROM words WHERE group_name = ? ORDER BY word"
                     (list group-filter))))))

(defun lexforge-list--insert-word-line (word-record)
  "Insert a line for WORD-RECORD."
  (let* ((id (nth 0 word-record))
         (word (nth 1 word-record))
         (state (nth 3 word-record))
         (suspended (= 1 (or (nth 4 word-record) 0)))
         (group (or (nth 5 word-record) "-"))
         (state-char (cond
                      ((string= state "new") "N")
                      ((string= state "learning") "L")
                      ((string= state "review") "R")
                      ((string= state "relearning") "r")
                      (t "?")))
         (state-face (cond
                      ((string= state "new") 'font-lock-keyword-face)
                      ((string= state "learning") 'font-lock-warning-face)
                      ((string= state "review") 'font-lock-string-face)
                      (t 'font-lock-comment-face))))
    (insert (propertize (if suspended "⏸" " ") 'face 'font-lock-comment-face))
    (insert (propertize state-char 'face state-face))
    (insert " ")
    (insert (propertize word 'face '(:weight bold)))
    (insert (propertize (format "  [%s]" group) 'face 'shadow))
    (insert "\n")
    (put-text-property (line-beginning-position 0) (point) 'lexforge-word-id id)
    (put-text-property (line-beginning-position 0) (point) 'lexforge-word word)))

(defun lexforge-list--current-word-id ()
  "Get word id at point."
  (get-text-property (point) 'lexforge-word-id))

(defun lexforge-list--current-word ()
  "Get word record at point."
  (when-let ((id (lexforge-list--current-word-id)))
    (seq-find (lambda (w) (= (nth 0 w) id)) lexforge-list--words)))

(defun lexforge-list--current-word-text ()
  "Get word text at point."
  (get-text-property (point) 'lexforge-word))

;; Navigation
(defun lexforge-list-next ()
  "Move to next word."
  (interactive)
  (forward-line 1)
  (while (and (not (eobp)) (not (lexforge-list--current-word-id)))
    (forward-line 1)))

(defun lexforge-list-prev ()
  "Move to previous word."
  (interactive)
  (forward-line -1)
  (while (and (not (bobp)) (not (lexforge-list--current-word-id)))
    (forward-line -1)))

;; Actions
(defun lexforge-list-open-org ()
  "Open org file and goto word at point.
Use org-refile to move words between groups."
  (interactive)
  (when-let ((word (lexforge-list--current-word-text)))
    (unless (lexforge-org-goto-word word)
      (message "Org entry not found for %s" word))))

(defun lexforge-list-sync ()
  "Sync from org files to database."
  (interactive)
  (lexforge-sync)
  (lexforge-list-refresh))

(defun lexforge-list-view-word ()
  "View word details at point."
  (interactive)
  (when-let* ((word-rec (lexforge-list--current-word))
              (id (nth 0 word-rec))
              (word (nth 1 word-rec)))
    (with-current-buffer (get-buffer-create "*Lexforge Word*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "━━━ %s ━━━\n\n" word) 'face '(:weight bold :height 1.5)))
        ;; Phonetic
        (when-let ((ph (nth 2 word-rec)))
          (insert (format "Phonetic: %s\n\n" ph)))
        ;; Definitions
        (let ((defs (lexforge-db-get-definitions id)))
          (when defs
            (insert (propertize "Definitions:\n" 'face 'font-lock-keyword-face))
            (dolist (d defs)
              (insert (format "  %s %s\n"
                              (propertize (or (nth 1 d) "") 'face (lexforge--pos-face (or (nth 1 d) "")))
                              (nth 2 d))))
            (insert "\n")))
        ;; Examples
        (let ((exs (lexforge-db-get-examples id)))
          (when exs
            (insert (propertize "Examples:\n" 'face 'font-lock-keyword-face))
            (dolist (e exs)
              (insert (format "  • %s\n" (nth 1 e)))
              (when (nth 2 e)
                (insert (propertize (format "    %s\n" (nth 2 e)) 'face 'font-lock-comment-face))))
            (insert "\n")))
        ;; Relations
        (let ((rels (lexforge-db-get-relations id)))
          (when rels
            (insert (propertize "Related: " 'face 'font-lock-keyword-face))
            (insert (string-join (mapcar (lambda (r) (nth 1 r)) rels) ", "))
            (insert "\n")))
        (goto-char (point-min))
        (special-mode))
      (display-buffer (current-buffer)))))

(defun lexforge-list-refresh-word ()
  "Refresh AI data for word at point."
  (interactive)
  (when-let* ((word-rec (lexforge-list--current-word))
              (id (nth 0 word-rec))
              (word (nth 1 word-rec)))
    (message "Refreshing %s..." word)
    (lexforge--fetch-word-data word id)))

(defun lexforge-list-suspend-toggle ()
  "Toggle suspend for word at point."
  (interactive)
  (when-let* ((id (lexforge-list--current-word-id)))
    (let* ((db (lexforge-db--ensure-connection))
           (current (caar (sqlite-select db "SELECT suspended FROM words WHERE id = ?" (list id))))
           (new-val (if (= current 0) 1 0)))
      (sqlite-execute db "UPDATE words SET suspended = ? WHERE id = ?" (list new-val id))
      (message (if (= new-val 1) "Suspended" "Resumed"))
      (lexforge-list-refresh))))

(defun lexforge-list-switch-group ()
  "Switch to another group."
  (interactive)
  (lexforge-list))

(defun lexforge-list-refresh ()
  "Refresh current list."
  (interactive)
  (let ((group-filter (cond
                       ((null lexforge-list--group) "All")
                       (t lexforge-list--group))))
    (lexforge-list--refresh-contents group-filter)))

(defun lexforge-list-play-word ()
  "Play word at point."
  (interactive)
  (when-let* ((word-rec (lexforge-list--current-word))
              (word (nth 1 word-rec)))
    (lexforge-tts-speak word)))

(defun lexforge--extract-word ()
  "Extract word or phrase from region or point.
If region is active, capture the entire phrase (preserving spaces).
Otherwise, capture the word at point."
  (let ((raw (if (use-region-p)
                 (buffer-substring-no-properties (region-beginning) (region-end))
               (thing-at-point 'word t))))
    (when raw
      ;; Clean leading/trailing whitespace and punctuation, preserve spaces for phrases
      (let ((cleaned (string-trim raw)))
        ;; Remove non-letter chars at start/end, preserve middle content
        (setq cleaned (replace-regexp-in-string "^[^a-zA-Z]+" "" cleaned))
        (setq cleaned (replace-regexp-in-string "[^a-zA-Z]+$" "" cleaned))
        (downcase cleaned)))))

(defun lexforge--get-context ()
  "Get context sentence."
  (cond
   ((eq major-mode 'pdf-view-mode)
    (when (bound-and-true-p pdf-view-active-region)
      (car (pdf-view-active-region-text))))
   (t (thing-at-point 'sentence t))))

(defun lexforge--fetch-word-data (word group)
  "Fetch AI data for WORD in GROUP, update Org file only (async).
If lexdb is loaded, uses stored context for better sense selection."
  (let ((context (when (lexforge-lexdb--available-p)
                   (lexforge-org-get-context word group))))
    (lexforge-ai-analyze-word
     word
     (lambda (data)
       (lexforge--process-word-data word group data))
     (lambda (err) (message "✗ %s: %s" word err))
     context)))

(defun lexforge--fetch-word-data-sync (word group)
  "Fetch AI data for WORD in GROUP synchronously.
If lexdb is loaded, uses stored context for better sense selection."
  (let ((result nil)
        (done nil)
        (err-msg nil)
        (context (when (lexforge-lexdb--available-p)
                   (lexforge-org-get-context word group))))
    (lexforge-ai-analyze-word
     word
     (lambda (data)
       (setq result data done t))
     (lambda (err)
       (setq err-msg err done t))
     context)
    ;; Wait for completion (max 30 seconds)
    (let ((timeout 30)
          (elapsed 0))
      (while (and (not done) (< elapsed timeout))
        (sleep-for 0.1)
        (setq elapsed (+ elapsed 0.1))))
    (if err-msg
        (message "✗ %s: %s" word err-msg)
      (when result
        (lexforge--process-word-data word group result)))))

(defun lexforge--process-word-data (word group data)
  "Process AI DATA for WORD in GROUP, update Org file."
  (let* ((lemma (alist-get 'lemma data))
         (is-phrase (lexforge--is-phrase-p word))
         (actual-word word))  ; default to original word
    ;; Handle lemmatization (only for single words, not phrases)
    (when (and lemma
               (not is-phrase)  ; skip lemmatization for phrases
               (not (string= lemma word)))
      (if (lexforge-org-find-word lemma)
          ;; lemma exists, delete current entry
          (progn
            (lexforge-org--delete-word word group)
            (message "'%s' -> '%s' (merged)" word lemma)
            (setq group nil))  ; no update needed, merged
        ;; Rename
        (lexforge-org--rename-word word lemma group)
        (setq actual-word lemma)
        (message "'%s' -> '%s'" word lemma)))
    ;; Update Org (full data)
    (when group
      (lexforge-org-update-word-data actual-word data group)
      (message "✓ %s" actual-word))))

;;;###autoload
(defun lexforge-capture (&optional group)
  "Capture word to GROUP (default: \"default\")."
  (interactive)
  (let ((word (or (lexforge--extract-word) (read-string "Word: ")))
        (target-group (or group "default")))
    (when (string-empty-p word) (user-error "No word"))
    (when (lexforge-org-find-word word)
      (user-error "'%s' already exists" word))
    (lexforge-org-add-word word (lexforge--get-context) target-group)
    (message "✓ %s [%s]" word target-group)))

;;;###autoload
(defun lexforge-capture-to-group ()
  "Capture word to a specific group."
  (interactive)
  (let* ((word (or (lexforge--extract-word) (read-string "Word: ")))
         (groups (lexforge-db-get-all-groups))
         (group (completing-read "Add to group: " (cons "default" groups) nil nil)))
    (when (string-empty-p word) (user-error "No word"))
    (when (string-empty-p group) (setq group "default"))
    (when (lexforge-org-find-word word)
      (user-error "'%s' already exists" word))
    (lexforge-org-add-word word (lexforge--get-context) group)
    (message "✓ %s [%s]" word group)))

;;;###autoload
(defun lexforge-capture-focus ()
  "Capture word with focus on specific meaning."
  (interactive)
  (let ((word (or (lexforge--extract-word) (read-string "Word: "))))
    (when (string-empty-p word) (user-error "No word"))
    (let ((focus (read-string (format "'%s' focus meaning (e.g. n. river bank): " word)))
          (group "default"))
      (if (lexforge-org-find-word word)
          ;; Already exists, prompt to edit in org
          (progn
            (message "'%s' exists, edit FOCUS property in org file" word)
            (lexforge-org-goto-word word))
        ;; New word
        (lexforge-org-add-word word (lexforge--get-context) group focus)
        (message "✓ %s [focus: %s]" word focus)))))

;;;###autoload
(defun lexforge-enrich ()
  "Analyze all unprocessed words in Org files.
Words without definitions section are considered unprocessed."
  (interactive)
  (let ((unprocessed (lexforge-org--get-unprocessed-words)))
    (if (null unprocessed)
        (message "All words analyzed")
      (let ((total (length unprocessed))
            (current 0))
        (message "Analyzing %d words..." total)
        (dolist (item unprocessed)
          (let ((word (car item))
                (group (cdr item)))
            (cl-incf current)
            (message "[%d/%d] Analyzing: %s" current total word)
            ;; Use sync mode to analyze one by one, avoid concurrency issues
            (lexforge--fetch-word-data-sync word group)))
        (message "✓ Analysis complete: %d words" total)))))

;;;###autoload
(defun lexforge-enrich-word (word)
  "Analyze a specific WORD from vocabulary."
  (interactive
   (list (completing-read "Analyze word: " (lexforge-org--get-all-words) nil t)))
  (let ((found (lexforge-org-find-word word)))
    (if found
        (progn
          (message "Analyzing: %s" word)
          (lexforge--fetch-word-data word (car found)))
      (user-error "'%s' not in vocabulary" word))))

(defun lexforge-org--get-unprocessed-words ()
  "Get words that haven't been analyzed (no definitions section).
Returns list of (word . group)."
  (let ((org-data (lexforge-org--parse-all-files))
        result)
    (dolist (group-data org-data)
      (let ((group (car group-data)))
        (dolist (entry (cdr group-data))
          (unless (alist-get 'definitions entry)
            (push (cons (alist-get 'word entry) group) result)))))
    (nreverse result)))

(defun lexforge-org--get-all-words ()
  "Get all words from all org files."
  (let ((org-data (lexforge-org--parse-all-files))
        words)
    (dolist (group-data org-data)
      (dolist (entry (cdr group-data))
        (push (alist-get 'word entry) words)))
    (nreverse words)))

;;;###autoload
(defun lexforge-play-word ()
  "Play word at point."
  (interactive)
  (when-let ((w (lexforge--extract-word)))
    (lexforge-tts-speak w)))

;;;###autoload
(defun lexforge-play-sentence ()
  "Play sentence at point."
  (interactive)
  (when-let ((s (thing-at-point 'sentence t)))
    (lexforge-tts-speak s)))

;;;###autoload
(defun lexforge-stats ()
  "Show stats."
  (interactive)
  (let ((total (lexforge-db-get-word-count))
        (today (lexforge-db-get-review-stats-today))
        (due (length (lexforge-db-get-due-words)))
        (new-count (length (lexforge-db-get-new-words)))
        (groups (length (lexforge-db-get-all-groups))))
    (message "Words:%d Groups:%d New:%d Due:%d Today:%d"
             total groups new-count due (or (nth 0 today) 0))))

;;;###autoload
(defun lexforge-debug-db ()
  "Debug: show database state."
  (interactive)
  (let* ((db (lexforge-db--ensure-connection))
         (words (sqlite-select db "SELECT word, state, suspended, due FROM words LIMIT 10"))
         (now-utc (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))
    (with-current-buffer (get-buffer-create "*lexforge-debug*")
      (erase-buffer)
      (insert "=== Database Debug ===\n\n")
      (insert (format "Current UTC time: %s\n" now-utc))
      (insert (format "Total words: %d\n" (lexforge-db-get-word-count)))
      (insert (format "New words (state='new'): %d\n" (length (lexforge-db-get-new-words))))
      (insert (format "Due words (due <= now): %d\n" (length (lexforge-db-get-due-words))))
      (insert (format "Learning words (due <= now): %d\n" (length (lexforge-db-get-learning-words))))
      (insert (format "All learnable words: %d\n" (length (lexforge-db-get-all-learnable-words))))
      (insert "\nFirst 10 words:\n")
      (dolist (w words)
        (let* ((due-time (nth 3 w))
               (is-due (and due-time (string< due-time now-utc))))
          (insert (format "  %s | state=%s | suspended=%s | due=%s %s\n"
                          (nth 0 w) (nth 1 w) (nth 2 w) due-time
                          (if is-due "[DUE]" "[NOT DUE]")))))
      (display-buffer (current-buffer)))))

;;; Group management commands
;;;###autoload
(defun lexforge-group-create (name)
  "Create a new group NAME by creating an org file."
  (interactive "sNew group name: ")
  (when (string-empty-p name) (user-error "Name cannot be empty"))
  (let ((file (lexforge-org--ensure-group-file name)))
    (find-file file)
    (message "Group created: %s" name)))

;;;; ============================================================
;;;; Mode Definition
;;;; ============================================================
;;;; Keymap & Mode
;;;; ============================================================

(defvar lexforge-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "c" #'lexforge-capture)
    (define-key map "C" #'lexforge-capture-to-group)
    (define-key map "f" #'lexforge-capture-focus)
    (define-key map "l" #'lexforge-learn)             ; learn due words
    (define-key map "L" #'lexforge-learn-all)         ; learn all words (ignore schedule)
    (define-key map "t" #'lexforge-type-examples)
    (define-key map "e" #'lexforge-generate-essay)
    (define-key map "p" #'lexforge-play-word)
    (define-key map "s" #'lexforge-play-sentence)
    (define-key map "d" #'lexforge-open-directory)
    (define-key map "o" #'lexforge-open-group)
    (define-key map "r" #'lexforge-enrich)           ; batch analyze unprocessed words
    (define-key map "R" #'lexforge-enrich-word)      ; analyze specific word
    (define-key map "S" #'lexforge-stats)
    (define-key map "y" #'lexforge-sync)
    (define-key map "b" #'lexforge-build)
    (define-key map "G" #'lexforge-list)
    (define-key map "n" #'lexforge-group-create)
    map)
  "Keymap for lexforge commands.
Bind this to your preferred prefix, e.g.:
  (global-set-key (kbd \"C-c v\") \\='lexforge-command-map)
Or with use-package:
  :bind-keymap (\"C-c v\" . lexforge-command-map)")

;; Make it a named prefix command
(fset 'lexforge-command-map lexforge-command-map)

(add-hook 'kill-emacs-hook (lambda () (lexforge-db-close) (lexforge-tts-stop)))

(provide 'lexforge)
;;; lexforge.el ends here

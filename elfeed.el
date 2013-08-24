;;; elfeed.el --- an Emacs web feed reader -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;;; Commentary:

;; Elfreed is a web feed client for Emacs, inspired by notmuch. See
;; the README for full documentation.

;; Elfreed requires Emacs 24 (lexical closures).

;;; Code:

(require 'cl)
(require 'xml)

(defgroup elfeed nil
  "An Emacs web feed reader."
  :group 'comm)

(defcustom elfeed-feeds ()
  "List of all feeds that elfeed should follow. You must add your
feeds to this list."
  :group 'elfeed
  :type 'list)

;; Model and Database

(defvar elfeed-db (make-hash-table :test 'equal)
  "The core database for elfeed.")

(defvar elfeed-initial-tags '(unread)
  "Initial tags for new entries.")

(defstruct elfeed-feed
  "A web feed, contains elfeed-entry structs."
  title url entries)

(defstruct elfeed-entry
  "A single entry from a feed, normalized towards Atom."
  title id link date content tags feed)

(defun elfeed-tag (entry &rest tags)
  "Add a tag to an entry."
  (let ((current (elfeed-entry-tags entry)))
    (setf (elfeed-entry-tags entry) (append tags current))))

(defun elfeed-untag (entry &rest tags)
  "Remove tags from an entry."
  (setf (elfeed-entry-tags entry)
        (loop for tag in (elfeed-entry-tags entry)
              unless (member tag tags) collect tag)))

(defun elfeed-tagged-p (tag entry)
  "Return true if ENTRY is tagged by TAG."
  (member tag (elfeed-entry-tags entry)))

(defun elfeed-db-get (url)
  "Get/create the table for URL."
  (let ((feed (gethash url elfeed-db)))
    (if feed
        feed
        (setf (gethash url elfeed-db)
              (make-elfeed-feed
               :url url :entries (make-hash-table :test 'equal))))))

(defun elfeed-db-put (url entries)
  "Add entries to the database under URL."
  (let* ((feed (elfeed-db-get url))
         (table (elfeed-feed-entries feed)))
    (loop for entry in entries
          for id = (elfeed-entry-id entry)
          for old = (gethash id table)
          when old  ; merge old tags back in
          do (setf (elfeed-entry-tags entry) (elfeed-entry-tags old))
          do (setf (gethash id table) entry))))

(defun elfeed-string> (a b)
  (string< b a))

(defun elfeed-sort (entries &optional old-first)
  "Destructively sort the given entries by date."
  (sort* entries (if old-first #'string< #'elfeed-string>)
         :key #'elfeed-entry-date))

(defun elfeed-db-entries (&optional url)
  "Get all the entries for a feed, sorted by date."
  (elfeed-sort
   (if (null url)
       (loop for url in elfeed-feeds
             append (elfeed-db-entries url))
     (loop for entry hash-values of (elfeed-feed-entries (elfeed-db-get url))
           collect entry))))

;; Fetching:

(defcustom elfeed-max-connections 6
  "The maximum number of feeds to be fetched in parallel."
  :group 'elfeed
  :type 'integer)

(defvar elfeed-connections nil
  "List of callbacks awaiting responses.")

(defvar elfeed-waiting nil
  "List of requests awaiting connections.")

(defvar elfeed--connection-counter 0
  "Provides unique connection identifiers.")

(defun elfeed--check-queue ()
  "Start waiting connections if connection slots are available."
  (while (and elfeed-waiting
              (< (length elfeed-connections) elfeed-max-connections))
    (let ((request (pop elfeed-waiting)))
      (destructuring-bind (id url cb) request
        (push request elfeed-connections)
        (url-retrieve url cb)))))

(defun elfeed--wrap-callback (id cb)
  "Return a function that manages the elfeed queue."
  (lambda (status)
    (setf elfeed-connections (delete* id elfeed-connections :key #'car))
    (elfeed--check-queue)
    (funcall cb status)))

(defun elfeed-fetch (url callback)
  "Basically wraps `url-retrieve' but uses the connection limiter."
  (let* ((id (incf elfeed--connection-counter))
         (cb (elfeed--wrap-callback id callback)))
    (push (list id url cb) elfeed-waiting)
    (elfeed--check-queue)))

(defmacro with-elfeed-fetch (url &rest body)
  "Asynchronously run BODY in a buffer with the contents from
URL. This macro is anaphoric, with STATUS referring to the status
from `url-retrieve'."
  (declare (indent defun))
  `(elfeed-fetch ,url (lambda (status) ,@body (kill-buffer))))

;; Parsing:

(defun elfeed-feed-type (content)
  "Return the feed type given the parsed content (:atom, :rss) or
NIL for unknown."
  (cadr (assoc (caar content) '((feed :atom) (rss :rss)))))

(defun elfeed-rfc3339 (&optional time)
  "Return an RFC 3339 formatted date string (Atom style)."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (if time (ignore-errors (date-to-time time)) nil) t))

(defun elfeed-cleanup (name)
  "Cleanup things that will be printed."
  (let ((trim (replace-regexp-in-string "^ +\\| +$" "" name)))
    (replace-regexp-in-string "[\n\t]+" " " trim)))

(defun elfeed-entries-from-atom (url xml)
  "Turn parsed Atom content into a list of elfeed-entry structs."
  (let ((feed (elfeed-db-get url))
        (title (xml-query '(feed title *) xml)))
    (setf (elfeed-feed-title feed) title)
    (loop for entry in (xml-query-all '(feed entry) xml) collect
          (let* ((title (or (xml-query '(title *) entry) ""))
                 (anylink (xml-query '(link :href) entry))
                 (altlink (xml-query '(link [rel "alternate"] :href) entry))
                 (link (or altlink anylink))
                 (id (or (xml-query '(id *) entry) link))
                 (date (or (xml-query '(published *) entry)
                           (xml-query '(updated *) entry)
                           (xml-query '(date *) entry))))
            (make-elfeed-entry :title (elfeed-cleanup title) :feed feed
                               :id (elfeed-cleanup id) :link link
                               :tags (copy-seq elfeed-initial-tags)
                               :date (elfeed-rfc3339 date) :content nil)))))

(defun elfeed-entries-from-rss (url xml)
  "Turn parsed RSS content into a list of elfeed-entry structs."
  (let ((feed (elfeed-db-get url))
        (title (xml-query '(rss channel title *) xml)))
    (setf (elfeed-feed-title feed) title)
    (loop for item in (xml-query-all '(rss channel item) xml) collect
          (let* ((title (or (xml-query '(title *) item) ""))
                 (link (xml-query '(link *) item))
                 (guid (xml-query '(guid *) item))
                 (id (or guid link))
                 (date (or (xml-query '(pubDate *) item)
                           (xml-query '(date *) item))))
            (make-elfeed-entry :title (elfeed-cleanup title)
                               :id (elfeed-cleanup id) :link link
                               :tags (copy-seq elfeed-initial-tags)
                               :date (elfeed-rfc3339 date) :content nil)))))

(defun elfeed-update-feed (url)
  "Update a specific feed."
  (interactive (list (completing-read "Feed: " elfeed-feeds)))
  (with-elfeed-fetch url
    (unless status
      (goto-char (point-min))
      (search-forward "\n\n") ; skip HTTP headers
      (set-buffer-multibyte t)
      (let* ((xml (xml-parse-region (point) (point-max)))
             (entries (case (elfeed-feed-type xml)
                        (:atom (elfeed-entries-from-atom url xml))
                        (:rss (elfeed-entries-from-rss url xml))
                        (t (error "Unkown feed type.")))))
        (elfeed-db-put url entries)))))

(defun elfeed-update ()
  "Update all the feeds in `elfeed-feeds'."
  (interactive)
  (mapc #'elfeed-update-feed elfeed-feeds))

;; Interface:

(defvar elfeed-search-entries ()
  "List of the entries currently on display.")

(defvar elfeed-search-mode-map
  (let ((map (make-sparse-keymap)))
    (prog1 map
      (define-key map "q" 'quit-window)
      (define-key map "g" 'elfeed-search-update)
      (define-key map "b" 'elfeed-search-browse-url)
      (define-key map "y" 'elfeed-search-yank)))
  "Keymap for elfeed-search-mode.")

(defun elfeed-search-mode ()
  "Major mode for listing elfeed feed entries."
  (interactive)
  (kill-all-local-variables)
  (use-local-map elfeed-search-mode-map)
  (setq major-mode 'elfeed-search-mode
        mode-name "elfeed-search"
        truncate-lines t
        buffer-read-only t)
  (make-local-variable 'elfeed-search-entries)
  (elfeed-search-update))

(defun elfeed-buffer ()
  (get-buffer-create "*elfeed-search*"))

(defun elfeed ()
  "Enter elfeed."
  (interactive)
  (switch-to-buffer (elfeed-buffer))
  (unless (eq major-mode 'elfeed-search-mode) (elfeed-search-mode))
  (elfeed-search-update))

(defun elfeed-search-format-date (date)
  "Format a date for printing in elfeed-search-mode."
  (let ((string (format-time-string "%Y-%m-%d" (date-to-time date))))
    (format "%-10.10s" string)))

(defface elfeed-search-date-face
  '((((class color) (background light)) (:foreground "#333"))
    (((class color) (background dark))  (:foreground "#77a")))
  "Face used in search mode for dates."
  :group 'elfeed)

(defface elfeed-search-title-face
  '((((class color) (background light)) (:foreground "#000"))
    (((class color) (background dark))  (:foreground "#fff")))
  "Face used in search mode for titles."
  :group 'elfeed)

(defface elfeed-search-feed-face
  '((((class color) (background light)) (:foreground "#0f0"))
    (((class color) (background dark))  (:foreground "#ff0")))
  "Face used in search mode for feed titles."
  :group 'elfeed)

(defun elfeed-search-update ()
  "Update the display to match the database."
  (interactive)
  (with-current-buffer (elfeed-buffer)
    (let ((inhibit-read-only t)
          (standard-output (current-buffer))
          (line (line-number-at-pos)))
      (erase-buffer)
      (loop for entry in (setf elfeed-search-entries (elfeed-db-entries))
            for date = (elfeed-search-format-date (elfeed-entry-date entry))
            for title = (elfeed-entry-title entry)
            for feed = (elfeed-entry-feed entry)
            for feedtitle = (elfeed-feed-title feed)
            do (insert (propertize date 'face 'elfeed-search-date-face))
            do (insert " ")
            do (insert (propertize title 'face 'elfeed-search-title-face))
            when feedtitle
            do (insert " ("
                       (propertize feedtitle 'face 'elfeed-search-feed-face)
                       ")")
            do (insert "\n"))
      (insert "End of entries.\n")
      (goto-line line))))

(defun elfeed-search-selected (&optional ignore-region)
  "Return a list of the currently selected feeds."
  (let ((use-region (and (not ignore-region) (use-region-p))))
    (let ((start (if use-region (region-beginning) (point)))
          (end   (if use-region (region-end)       (point))))
      (loop for line from (line-number-at-pos start) to (line-number-at-pos end)
            when (nth (1- line) elfeed-search-entries)
            collect it into selected
            finally (return (if ignore-region (car selected) selected))))))

(defun elfeed-search-browse-url ()
  "Visit the current entry in your browser using `browse-url'."
  (interactive)
  (loop for entry in (elfeed-search-selected)
        when (elfeed-entry-link entry)
        do (browse-url it)))

(defun elfeed-search-yank ()
  "Copy the selected feed item to "
  (interactive)
  (let* ((entry (elfeed-search-selected :ignore-region))
         (link (and entry (elfeed-entry-link entry))))
    (when entry
      (message "Copied: %s" link)
      (x-set-selection 'PRIMARY link))))

(provide 'elfeed)

;;; elfeed.el ends here
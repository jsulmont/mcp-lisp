;;;; src/agent/tools.lisp
;;;;
;;;; Built-in tools for the REPL agent.

(defpackage #:mcp-lisp/src/agent/tools
  (:use #:cl)
  (:import-from #:bordeaux-threads)
  (:import-from #:mcp-lisp/src/primitives/tools/define-tool
                #:define-tool
                #:session)
  (:import-from #:mcp-lisp/src/agent/util
                #:read-key-file)
  (:import-from #:mcp-lisp/src/transport/mcp-woo
                #:*session-cleanup-hook*)
  (:import-from #:dexador)
  (:export #:reset-sandbox
           #:cleanup-session-sandbox
           #:*search-api-key*))

(in-package #:mcp-lisp/src/agent/tools)

;;; Per-session sandbox packages.
;;; When SESSION is nil (run-agent REPL), falls back to a global sandbox.

(defvar *sandbox-counter* 0)
(defvar *sandbox-counter-lock* (bt:make-lock "sandbox-counter"))
(defvar *session-sandboxes* (make-hash-table :test #'eq :synchronized t))

(defun sandbox-use-list ()
  "Packages available in eval sandboxes. Includes mcp-lisp when loaded."
  (let ((pkgs (list :cl)))
    (when (find-package :mcp-lisp)
      (push :mcp-lisp pkgs))
    pkgs))

(defun make-sandbox ()
  (let ((n (bt:with-lock-held (*sandbox-counter-lock*)
             (incf *sandbox-counter*))))
    (make-package (format nil "AGENT-SANDBOX-~A" n) :use (sandbox-use-list))))

(defun delete-sandbox (pkg)
  (when pkg
    (do-symbols (sym pkg) (unintern sym pkg))
    (delete-package pkg)))

(defun ensure-sandbox (&optional session)
  (if (null session)
      (let ((pkg (or (find-package :agent-sandbox)
                     (make-package :agent-sandbox :use (sandbox-use-list)))))
        ;; The global sandbox may have been created before :mcp-lisp was loaded
        ;; (package-inferred-system loads tools.lisp before main.lisp).
        ;; Patch the use-list if needed.
        (when (and (find-package :mcp-lisp)
                   (not (member (find-package :mcp-lisp)
                                (package-use-list pkg))))
          (use-package :mcp-lisp pkg))
        pkg)
      (or (gethash session *session-sandboxes*)
          (setf (gethash session *session-sandboxes*) (make-sandbox)))))

(defun reset-sandbox (&optional session)
  "Delete and recreate the sandbox. Per-session when SESSION is provided."
  (if (null session)
      (let ((pkg (find-package :agent-sandbox)))
        (when pkg (delete-sandbox pkg))
        (make-package :agent-sandbox :use (sandbox-use-list)))
      (let ((old (gethash session *session-sandboxes*)))
        (when old (delete-sandbox old))
        (setf (gethash session *session-sandboxes*) (make-sandbox))))
  t)

(defun cleanup-session-sandbox (session)
  "Remove and delete the sandbox for SESSION. Called on session teardown."
  (let ((pkg (gethash session *session-sandboxes*)))
    (when pkg
      (delete-sandbox pkg)
      (remhash session *session-sandboxes*))))

(ensure-sandbox)
(setf *session-cleanup-hook* #'cleanup-session-sandbox)

(defun json-serializable-p (value)
  "Return T if VALUE can be directly serialized to JSON."
  (typecase value
    ((or hash-table vector string number) t)
    (null t)  ; encodes as JSON null/false
    (t nil)))

(defun result-to-string (value)
  "Render a single eval result as a string.
JSON-serializable structures are encoded as JSON to avoid unreadable
print forms like #<HASH-TABLE ...> and to prevent escape accumulation
in nested eval scenarios."
  (if (and (json-serializable-p value)
           (not (stringp value))  ; strings print fine with ~s
           (not (numberp value))) ; numbers print fine with ~s
      (mcp-lisp/src/json:encode-json value)
      (prin1-to-string value)))

;;; eval_lisp - Evaluate Lisp forms with warning/error capture

(define-tool eval-lisp ((code string "The Lisp code to evaluate" :required t))
  "Evaluate Lisp code in the sandbox. Supports multiple forms - each form is
evaluated in sequence, so definitions are available to subsequent forms.
Captures printed output, warnings, and errors."
  (:annotations :destructive t :idempotent nil)
  (let ((sandbox (ensure-sandbox session))
        (warnings nil)
        (results nil)
        (error-msg nil)
        (printed-output nil))
    (handler-bind
        ((warning (lambda (w)
                    (push (princ-to-string w) warnings)
                    (muffle-warning w))))
      (handler-case
          (let ((*package* sandbox))
            (setf printed-output
                  (with-output-to-string (*standard-output*)
                    (loop with pos = 0
                          with len = (length code)
                          while (< pos len)
                          do (multiple-value-bind (form new-pos)
                                 (read-from-string code nil :eof :start pos)
                               (when (eq form :eof)
                                 (return))
                               (setf pos new-pos)
                               (push (eval form) results))))))
        (error (e)
          (setf error-msg (princ-to-string e)))))
    (let ((last-result (car (last results))))
      (with-output-to-string (out)
        (when (and printed-output (plusp (length printed-output)))
          (format out "Output:~%~a~%" printed-output))
        (when warnings
          (format out "Warnings:~%")
          (dolist (w (nreverse warnings))
            (format out "  ~a~%" w)))
        (when error-msg
          (format out "Error: ~a~%" error-msg))
        (when last-result
          (format out "=> ~a" (result-to-string last-result)))))))

;;; clear_repl - Reset the sandbox

(define-tool clear-repl ()
  "Clear all definitions from the REPL sandbox. Use this to start fresh
with a clean environment. All previously defined functions and variables
will be removed."
  (:annotations :destructive t :idempotent t)
  (reset-sandbox session)
  "Sandbox cleared. All definitions have been removed.")

;;; shell - Execute shell commands

(define-tool shell ((command string "The shell command to execute" :required t))
  "Execute a shell command and return stdout/stderr. Use for file operations,
system commands, git, etc."
  (:annotations :destructive t :open-world t)
  (multiple-value-bind (output error-output exit-code)
      (uiop:run-program command
                        :output :string
                        :error-output :string
                        :ignore-error-status t)
    (with-output-to-string (out)
      (when (and output (plusp (length output)))
        (write-string output out))
      (when (and error-output (plusp (length error-output)))
        (format out "~@[~&stderr: ~a~]" error-output))
      (unless (zerop exit-code)
        (format out "~&Exit code: ~a" exit-code)))))

;;; read_file - Read file contents

(define-tool read-file ((path string "Path to the file to read" :required t))
  "Read and return the contents of a file."
  (:annotations :read-only t)
  (handler-case
      (uiop:read-file-string path)
    (error (e)
      (format nil "Error reading file: ~a" e))))

;;; write_file - Write file contents

(define-tool write-file ((path string "Path to the file to write" :required t)
                         (content string "Content to write" :required t)
                         (if-exists string "Behavior when file exists: overwrite (default), append, or error"
                                    :default "overwrite"))
  "Write content to a file. Creates parent directories if needed."
  (:annotations :destructive t)
  (ensure-directories-exist (pathname path))
  (let ((exists-action (cond ((string-equal if-exists "append") :append)
                             ((string-equal if-exists "error")
                              (when (probe-file path)
                                (return-from write-file-handler
                                  (format nil "Error: file already exists: ~a" path)))
                              :supersede)
                             (t :supersede))))
    (handler-case
        (progn
          (with-open-file (out path :direction :output
                                    :if-exists exists-action
                                    :if-does-not-exist :create
                                    :external-format :utf-8)
            (write-string content out))
          (format nil "Wrote ~a bytes to ~a" (length content) path))
      (error (e)
        (format nil "Error writing file: ~a" e)))))

;;; list_tools - List available tools (meta-tool)

(define-tool list-tools ()
  "List all available tools and their descriptions."
  (:annotations :read-only t)
  (with-output-to-string (out)
    (format out "Available tools:~%")
    (dolist (tool (mcp-lisp/src/primitives/tools/registry:get-all-tools))
      (format out "  ~a: ~a~%"
              (mcp-lisp/src/primitives/tools/registry:tool-entry-name tool)
              (mcp-lisp/src/primitives/tools/registry:tool-entry-description tool)))))

;;; web_search - Search the web via Tavily

(defvar *search-api-key* (or (uiop:getenv "TAVILY_API_KEY")
                              (read-key-file ".tavily-key"))
  "Tavily API key. Checked: TAVILY_API_KEY env var, then ~/.tavily-key.")

(define-tool web-search ((query string "Search query" :required t)
                         (max-results integer "Number of results (1-10)" :default 5))
  "Search the web using Tavily and return results with titles, URLs, and content snippets."
  (:annotations :read-only t :open-world t)
  (unless *search-api-key*
    (error 'mcp-lisp/src/conditions:tool-error
           :message "Tavily API key not found. Set TAVILY_API_KEY env var, write ~/.tavily-key, or set *search-api-key* directly."
           :category :permission))
  (let ((clamped-max (max 1 (min 10 (or max-results 5)))))
    (multiple-value-bind (response-body status)
        (dex:post "https://api.tavily.com/search"
                  :headers '(("Content-Type" . "application/json"))
                  :read-timeout 15
                  :connect-timeout 5
                  :content (mcp-lisp/src/json:encode-json
                            (mcp-lisp/src/json:make-ht
                             "query" query
                             "max_results" clamped-max
                             "api_key" *search-api-key*)))
      (unless (= status 200)
        (error 'mcp-lisp/src/conditions:tool-error
               :message (format nil "Tavily API error (~a): ~a" status response-body)
               :category :transient
               :retryable t))
      (let* ((data (mcp-lisp/src/json:decode-json response-body))
             (results (gethash "results" data)))
        (with-output-to-string (out)
          (loop for result across results
                for i from 1
                do (format out "~a. ~a~%   ~a~%   ~a~%~%"
                           i
                           (gethash "title" result)
                           (gethash "url" result)
                           (gethash "content" result))))))))

;;; http_fetch - Fetch a URL

(define-tool http-fetch ((url string "URL to fetch" :required t)
                         (max-bytes integer "Maximum response bytes to return" :default 100000))
  "Fetch the contents of a URL via HTTP GET and return the response body."
  (:annotations :read-only t :open-world t)
  (handler-case
      (multiple-value-bind (body status)
          (dex:get url :read-timeout 15 :connect-timeout 5
                       :want-stream nil
                       :force-string t)
        (if (<= 200 status 299)
            (if (> (length body) (or max-bytes 100000))
                (subseq body 0 (or max-bytes 100000))
                body)
            (format nil "HTTP ~a: ~a" status
                    (subseq body 0 (min (length body) 500)))))
    (error (e)
      (format nil "Error fetching ~a: ~a" url e))))

;;; diff - Unified diff between two strings or files

(define-tool diff ((a string "First string or file path" :required t)
                   (b string "Second string or file path" :required t)
                   (as-files boolean "Treat a and b as file paths" :default nil))
  "Return a unified diff between two strings, or between two files when as_files is true."
  (:annotations :read-only t)
  (flet ((resolve (x)
           (if as-files
               (handler-case (uiop:read-file-string x)
                 (error (e) (return-from diff-handler
                              (format nil "Error reading ~a: ~a" x e))))
               x)))
    (let* ((text-a (resolve a))
           (text-b (resolve b))
           (lines-a (uiop:split-string text-a :separator '(#\Newline)))
           (lines-b (uiop:split-string text-b :separator '(#\Newline)))
           (len-a (length lines-a))
           (len-b (length lines-b)))
      ;; Simple LCS-based unified diff
      (let* ((dp (make-array (list (1+ len-a) (1+ len-b)) :initial-element 0)))
        ;; Build LCS table
        (loop for i from 1 to len-a
              do (loop for j from 1 to len-b
                       do (setf (aref dp i j)
                                (if (string= (nth (1- i) lines-a) (nth (1- j) lines-b))
                                    (1+ (aref dp (1- i) (1- j)))
                                    (max (aref dp (1- i) j) (aref dp i (1- j)))))))
        ;; Backtrack to produce diff
        (let ((hunks nil)
              (i len-a)
              (j len-b))
          (loop while (or (plusp i) (plusp j))
                do (cond
                     ((and (plusp i) (plusp j)
                           (string= (nth (1- i) lines-a) (nth (1- j) lines-b)))
                      (push (cons :ctx (nth (1- i) lines-a)) hunks)
                      (decf i) (decf j))
                     ((and (plusp j)
                           (or (zerop i)
                               (> (aref dp i (1- j)) (aref dp (1- i) j))))
                      (push (cons :add (nth (1- j) lines-b)) hunks)
                      (decf j))
                     (t
                      (push (cons :del (nth (1- i) lines-a)) hunks)
                      (decf i))))
          (if (every (lambda (h) (eq (car h) :ctx)) hunks)
              "No differences."
              (with-output-to-string (out)
                (dolist (h hunks)
                  (ecase (car h)
                    (:ctx (format out " ~a~%" (cdr h)))
                    (:add (format out "+~a~%" (cdr h)))
                    (:del (format out "-~a~%" (cdr h))))))))))))

;;; grep_files - Search file contents (rg or grep)

(defun find-executable (&rest names)
  "Return the first executable found in PATH, or NIL."
  (loop for name in names
        for path = (ignore-errors
                     (string-trim '(#\Newline #\Space #\Return)
                                  (uiop:run-program (list "which" name)
                                                    :output :string
                                                    :ignore-error-status t)))
        when (and path (plusp (length path)))
          return (values path name)))

(let ((grep-cmd (find-executable "rg" "grep")))
  (when grep-cmd
    (define-tool grep-files
        ((pattern string "Search pattern (regex)" :required t)
         (path string "Directory or file to search" :default ".")
         (glob string "File glob filter (e.g. \"*.lisp\")" :default nil)
         (max-results integer "Maximum number of matching lines" :default 50))
      "Search file contents for a pattern. Returns matching lines with filenames and line numbers."
      (:annotations :read-only t)
      (let* ((use-rg (search "rg" grep-cmd))
             (args (if use-rg
                       (append (list grep-cmd "-n" "--no-heading" "--color=never"
                                     "-m" (princ-to-string (or max-results 50)))
                               (when glob (list "-g" glob))
                               (list pattern (or path ".")))
                       (append (list grep-cmd "-rn" "--color=never")
                               (when glob (list "--include" glob))
                               (list pattern (or path "."))))))
        (multiple-value-bind (output error-output exit-code)
            (uiop:run-program args :output :string :error-output :string
                                   :ignore-error-status t)
          (declare (ignore error-output))
          (if (zerop exit-code)
              (let ((lines (uiop:split-string output :separator '(#\Newline))))
                (format nil "~{~a~%~}" (subseq lines 0 (min (length lines)
                                                             (or max-results 50)))))
              (if (= exit-code 1) "No matches found." output)))))))

;;; find_files - Find files by name (fd or find)

(let ((find-cmd (find-executable "fd" "find")))
  (when find-cmd
    (define-tool find-files
        ((pattern string "File name pattern" :required t)
         (path string "Directory to search" :default ".")
         (file-type string "Filter: file, directory, or symlink" :default nil))
      "Find files by name pattern. Returns matching file paths."
      (:annotations :read-only t)
      (let* ((use-fd (search "fd" find-cmd))
             (args (if use-fd
                       (append (list find-cmd "--color=never")
                               (when file-type
                                 (list "-t" (cond ((string-equal file-type "file") "f")
                                                  ((string-equal file-type "directory") "d")
                                                  ((string-equal file-type "symlink") "l")
                                                  (t file-type))))
                               (list pattern (or path ".")))
                       (append (list find-cmd (or path "."))
                               (when file-type
                                 (list "-type" (cond ((string-equal file-type "file") "f")
                                                     ((string-equal file-type "directory") "d")
                                                     ((string-equal file-type "symlink") "l")
                                                     (t file-type))))
                               (list "-name" pattern)))))
        (multiple-value-bind (output error-output exit-code)
            (uiop:run-program args :output :string :error-output :string
                                   :ignore-error-status t)
          (declare (ignore error-output exit-code))
          output)))))

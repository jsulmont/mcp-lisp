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

(defun make-sandbox ()
  (let ((n (bt:with-lock-held (*sandbox-counter-lock*)
             (incf *sandbox-counter*))))
    (make-package (format nil "AGENT-SANDBOX-~A" n) :use '(:cl))))

(defun delete-sandbox (pkg)
  (when pkg
    (do-symbols (sym pkg) (unintern sym pkg))
    (delete-package pkg)))

(defun ensure-sandbox (&optional session)
  (if (null session)
      (or (find-package :agent-sandbox)
          (make-package :agent-sandbox :use '(:cl)))
      (or (gethash session *session-sandboxes*)
          (setf (gethash session *session-sandboxes*) (make-sandbox)))))

(defun reset-sandbox (&optional session)
  "Delete and recreate the sandbox. Per-session when SESSION is provided."
  (if (null session)
      (let ((pkg (find-package :agent-sandbox)))
        (when pkg (delete-sandbox pkg))
        (make-package :agent-sandbox :use '(:cl)))
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
    (let ((final-results (nreverse results)))
      (with-output-to-string (out)
        (when (and printed-output (plusp (length printed-output)))
          (format out "Output:~%~a~%" printed-output))
        (when warnings
          (format out "Warnings:~%")
          (dolist (w (nreverse warnings))
            (format out "  ~a~%" w)))
        (when error-msg
          (format out "Error: ~a~%" error-msg))
        (format out "Results: ~{~a~^, ~}"
                (mapcar #'result-to-string final-results))))))

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

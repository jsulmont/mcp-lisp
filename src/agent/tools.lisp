;;;; src/agent/tools.lisp
;;;;
;;;; Built-in tools for the REPL agent.

(defpackage #:mcp-lisp/src/agent/tools
  (:use #:cl)
  (:import-from #:mcp-lisp/src/primitives/tools/define-tool
                #:define-tool)
  (:export #:reset-sandbox))

(in-package #:mcp-lisp/src/agent/tools)

;;; Sandbox package for isolated evaluation

(defun ensure-sandbox ()
  "Ensure the sandbox package exists, creating it if needed."
  (or (find-package :agent-sandbox)
      (make-package :agent-sandbox :use '(:cl))))

(defun reset-sandbox ()
  "Delete and recreate the sandbox package for a clean slate."
  (let ((pkg (find-package :agent-sandbox)))
    (when pkg
      (do-symbols (sym pkg)
        (unintern sym pkg))
      (delete-package pkg)))
  (make-package :agent-sandbox :use '(:cl))
  t)

;; Initialize sandbox on load
(ensure-sandbox)

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
  (ensure-sandbox)
  (let ((warnings nil)
        (results nil)
        (error-msg nil)
        (printed-output nil))
    ;; Capture compiler warnings and printed output
    (handler-bind
        ((warning (lambda (w)
                    (push (princ-to-string w) warnings)
                    (muffle-warning w))))
      (handler-case
          (let ((*package* (find-package :agent-sandbox)))
            ;; Capture any printed output
            (setf printed-output
                  (with-output-to-string (*standard-output*)
                    ;; Read and evaluate all forms
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
    ;; Return structured feedback
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
  (reset-sandbox)
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

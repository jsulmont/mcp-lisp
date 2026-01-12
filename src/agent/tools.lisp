;;;; src/agent/tools.lisp
;;;;
;;;; Built-in tools for the REPL agent.

(defpackage #:mcp-lisp/src/agent/tools
  (:use #:cl)
  (:import-from #:mcp-lisp/src/primitives/tools/define-tool
                #:define-tool))

(in-package #:mcp-lisp/src/agent/tools)

;;; eval_lisp - Evaluate Lisp forms with warning/error capture

(define-tool eval-lisp ((code string "The Lisp code to evaluate" :required t))
  "Evaluate a Lisp form and return the result. Captures and returns any
compilation warnings or errors along with the result, so you can debug issues."
  (let ((warnings nil)
        (result nil)
        (error-msg nil))
    ;; Capture compiler warnings
    (handler-bind
        ((warning (lambda (w)
                    (push (princ-to-string w) warnings)
                    (muffle-warning w))))
      (handler-case
          (setf result (eval (read-from-string code)))
        (error (e)
          (setf error-msg (princ-to-string e)))))
    ;; Return structured feedback
    (with-output-to-string (out)
      (when warnings
        (format out "Warnings:~%")
        (dolist (w (nreverse warnings))
          (format out "  ~a~%" w)))
      (when error-msg
        (format out "Error: ~a~%" error-msg))
      (format out "Result: ~s" result))))

;;; shell - Execute shell commands

(define-tool shell ((command string "The shell command to execute" :required t))
  "Execute a shell command and return stdout/stderr. Use for file operations,
system commands, git, etc."
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
  (handler-case
      (uiop:read-file-string path)
    (error (e)
      (format nil "Error reading file: ~a" e))))

;;; list_tools - List available tools (meta-tool)

(define-tool list-tools ()
  "List all available tools and their descriptions."
  (with-output-to-string (out)
    (format out "Available tools:~%")
    (dolist (tool (mcp-lisp/src/primitives/tools/registry:get-all-tools))
      (format out "  ~a: ~a~%"
              (mcp-lisp/src/primitives/tools/registry:tool-entry-name tool)
              (mcp-lisp/src/primitives/tools/registry:tool-entry-description tool)))))

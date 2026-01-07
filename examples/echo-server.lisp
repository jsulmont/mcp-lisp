#!/usr/bin/env sbcl --script
;;;; examples/echo-server.lisp
;;;;
;;;; Minimal MCP server example with an echo tool.

;;; Bootstrap: Load Quicklisp and ASDF, suppressing output for clean stdio
;;; We use EVAL to defer package resolution until after ASDF is loaded
(let ((*standard-output* (make-broadcast-stream))
      (*trace-output* (make-broadcast-stream))
      (*error-output* *error-output*)
      (this-file *load-truename*))
  ;; Load Quicklisp if available
  (let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file ql-setup)
      (load ql-setup)))
  ;; ASDF should now be loaded via Quicklisp
  (require :asdf)
  ;; Add project to search path and load (use eval to defer package resolution)
  (let* ((examples-dir (make-pathname :directory (pathname-directory this-file)))
         (project-dir (truename (merge-pathnames "../" examples-dir))))
    (eval `(pushnew ,project-dir ,(find-symbol "*CENTRAL-REGISTRY*" "ASDF") :test #'equal))
    (funcall (find-symbol "LOAD-SYSTEM" "ASDF") :mcp-lisp :verbose nil :print nil)))

;;; Define the server package
(defpackage #:echo-server
  (:use #:cl #:mcp-lisp/main))

(in-package #:echo-server)

;;; Define tools

(define-tool echo ((message string "The message to echo" :required t))
  "Echoes the input message back to the caller."
  (format nil "Echo: ~a" message))

(define-tool greet ((name string "Name to greet" :required t)
                    (excited boolean "Add exclamation" :default nil))
  "Greets someone by name."
  (if excited
      (format nil "Hello, ~a!" name)
      (format nil "Hello, ~a." name)))

;;; Define prompts

(define-prompt code-review ((code string "Code to review" :required t)
                            (language string "Programming language"))
  "Generate a code review prompt."
  (list (make-ht "role" "user"
                 "content" (make-ht "type" "text"
                                    "text" (format nil "Please review this ~a code:~%~%~a"
                                                   (or language "")
                                                   code)))))

(define-prompt summarize ((text string "Text to summarize" :required t))
  "Generate a summarization prompt."
  (list (make-ht "role" "user"
                 "content" (make-ht "type" "text"
                                    "text" (format nil "Please summarize the following:~%~%~a" text)))))

;;; Define resources

(define-resource "config://server/info"
  (:name "Server Info" :mime-type "application/json")
  "Returns server configuration information."
  (encode-json (make-ht "name" "echo-server"
                        "version" "1.0.0"
                        "uptime" (get-universal-time))))

(define-resource "config://server/capabilities"
  (:name "Server Capabilities" :mime-type "application/json")
  "Returns server capabilities."
  (encode-json (make-ht "tools" t
                        "prompts" t
                        "resources" t)))

;;; Start the server (using MCP stdio transport for Claude Code compatibility)
(setup-file-logging "/tmp/echo-server.log")
(run-server :name "echo-server" :version "1.0.0" :transport :mcp-stdio)

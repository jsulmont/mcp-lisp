;;;; examples/echo-server-sse.lisp
;;;;
;;;; MCP server example using HTTP/SSE transport.
;;;; Start with: sbcl --load examples/echo-server-sse.lisp
;;;; Then add to Claude: claude mcp add --transport sse echo-server http://localhost:8080/sse

;;; Bootstrap: Load Quicklisp and ASDF
(let ((*standard-output* (make-broadcast-stream))
      (*trace-output* (make-broadcast-stream))
      (*error-output* *error-output*)
      (this-file (or *load-truename* *default-pathname-defaults*)))
  (let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file ql-setup)
      (load ql-setup)))
  (require :asdf)
  (let* ((examples-dir (make-pathname :directory (pathname-directory this-file)))
         (project-dir (truename (merge-pathnames "../" examples-dir))))
    (eval `(pushnew ,project-dir ,(find-symbol "*CENTRAL-REGISTRY*" "ASDF") :test #'equal))
    (funcall (find-symbol "LOAD-SYSTEM" "ASDF") :mcp-lisp :verbose nil :print nil)))

;;; Define the server package
(defpackage #:echo-server-sse
  (:use #:cl #:mcp-lisp/main))

(in-package #:echo-server-sse)

;;; Define tools (same as stdio example)

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

;;; Define resources

(define-resource "config://server/info"
  (:name "Server Info" :mime-type "application/json")
  "Returns server configuration information."
  (encode-json (make-ht "name" "echo-server-sse"
                        "version" "1.0.0"
                        "transport" "sse"
                        "uptime" (get-universal-time))))

;;; Start the SSE server
(format t "~%Starting MCP SSE server...~%")
(format t "Add to Claude with:~%")
(format t "  claude mcp add --transport sse echo-server http://localhost:8080/sse~%~%")

(run-server :name "echo-server" :version "1.0.0" :transport :sse :port 8080)

;;; Keep the process alive
(loop (sleep 3600))

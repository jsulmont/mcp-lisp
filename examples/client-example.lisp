;;;; examples/client-example.lisp
;;;;
;;;; Example MCP client usage.

(require :asdf)

;;; Add the project to ASDF search path
(let ((project-dir (merge-pathnames "../" *load-truename*)))
  (pushnew project-dir asdf:*central-registry* :test #'equal))

(asdf:load-system :mcp-lisp)

(defpackage #:client-example
  (:use #:cl #:mcp-lisp/main))

(in-package #:client-example)

;;; Example 1: Manual client management
(defun example-manual ()
  "Demonstrate manual client lifecycle management."
  (format t "~%=== Manual Client Example ===~%")
  (let ((client (make-client "sbcl" "--script"
                             (namestring (merge-pathnames "echo-server.lisp"
                                                          *load-truename*)))))
    (unwind-protect
         (progn
           ;; Connect and initialize
           (client-connect client)
           (client-initialize client)

           ;; Print server info
           (format t "Connected to: ~a v~a~%"
                   (gethash "name" (client-server-info client))
                   (gethash "version" (client-server-info client)))
           (format t "Protocol: ~a~%" (client-protocol-version client))

           ;; List tools
           (format t "~%Available tools:~%")
           (dolist (tool (list-tools client))
             (format t "  - ~a: ~a~%"
                     (gethash "name" tool)
                     (gethash "description" tool)))

           ;; Call the echo tool
           (format t "~%Calling echo tool...~%")
           (let ((result (call-tool client "echo" :message "Hello from client!")))
             (format t "Result: ~a~%"
                     (gethash "text" (elt result 0)))))
      ;; Cleanup
      (client-shutdown client))))

;;; Example 2: Using with-client macro
(defun example-with-client ()
  "Demonstrate the with-client convenience macro."
  (format t "~%=== with-client Example ===~%")
  (with-client (c "sbcl" "--script"
                  (namestring (merge-pathnames "echo-server.lisp"
                                               *load-truename*)))
    (format t "Server: ~a~%" (gethash "name" (client-server-info c)))

    ;; Call greet tool
    (let ((result (call-tool c "greet" :name "World" :excited t)))
      (format t "Greeting: ~a~%" (gethash "text" (elt result 0))))

    ;; Ping
    (format t "Ping: ~a~%" (ping c))))

;;; Run examples
(format t "~%MCP Client Examples~%")
(format t "====================~%")

(handler-case
    (progn
      (example-manual)
      (example-with-client)
      (format t "~%All examples completed successfully!~%"))
  (error (e)
    (format t "~%Error: ~a~%" e)))

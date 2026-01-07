;;;; test-client.lisp - Test client against echo server

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (truename ".") asdf:*central-registry*)
(ql:quickload :mcp-lisp :silent t)

(defpackage #:test-client
  (:use #:cl #:mcp-lisp/main))

(in-package #:test-client)

(format t "~%=== Testing MCP Client ===~%")

(let* ((server-script (namestring (merge-pathnames "examples/echo-server.lisp"
                                                    (truename "."))))
       (client (make-client "sbcl" "--script" server-script)))
  (format t "Server script: ~a~%" server-script)

  (unwind-protect
       (handler-case
           (progn
             (format t "Connecting...~%")
             (client-connect client)

             (format t "Initializing...~%")
             (client-initialize client)

             (format t "Server info: ~a~%" (client-server-info client))
             (format t "Protocol: ~a~%" (client-protocol-version client))

             (format t "~%Listing tools...~%")
             (let ((tools (list-tools client)))
               (format t "Found ~a tools~%" (length tools))
               (dolist (tool (coerce tools 'list))
                 (format t "  - ~a~%" (gethash "name" tool))))

             (format t "~%Calling echo tool...~%")
             (let ((content (call-tool client "echo" :message "Hello from test!")))
               (format t "Content items: ~a~%" (length content))
               (let ((first (elt content 0)))
                 (format t "Text: ~a~%" (gethash "text" first))))

             (format t "~%Listing prompts...~%")
             (let ((prompts (list-prompts client)))
               (format t "Found ~a prompts~%" (length prompts))
               (dolist (prompt (coerce prompts 'list))
                 (format t "  - ~a~%" (gethash "name" prompt))))

             (format t "~%Getting code-review prompt...~%")
             (let ((messages (get-prompt client "code-review" :code "(defun foo () 42)")))
               (format t "Messages: ~a~%" (length messages))
               (let ((first (elt messages 0)))
                 (format t "Role: ~a~%" (gethash "role" first))
                 (let ((content (gethash "content" first)))
                   (format t "Content text: ~a~%" (gethash "text" content)))))

             (format t "~%Listing resources...~%")
             (let ((resources (list-resources client)))
               (format t "Found ~a resources~%" (length resources))
               (dolist (resource (coerce resources 'list))
                 (format t "  - ~a (~a)~%" (gethash "name" resource) (gethash "uri" resource))))

             (format t "~%Reading server info resource...~%")
             (let ((contents (read-resource client "config://server/info")))
               (format t "Contents: ~a~%" (length contents))
               (let ((first (elt contents 0)))
                 (format t "URI: ~a~%" (gethash "uri" first))
                 (format t "Text: ~a~%" (gethash "text" first))))

             (format t "~%SUCCESS: Client test passed!~%"))
         (error (e)
           (format t "~%ERROR: ~a~%" e)
           (sb-ext:exit :code 1)))
    (format t "Shutting down...~%")
    (client-shutdown client)))

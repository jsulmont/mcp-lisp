;;;; conformance-client.lisp
;;;; MCP conformance test client — connects to a test server provided by
;;;; npx @modelcontextprotocol/conformance client --command "sbcl --load conformance-client.lisp"
;;;; The framework appends the server URL as the last command-line argument.

(ql:quickload :mcp-lisp :silent t)

(defpackage #:conformance-client
  (:use #:cl)
  (:import-from #:mcp-lisp/src/client/client
                #:make-http-client #:client-connect #:client-initialize
                #:client-shutdown #:client-call #:client-notify
                #:client-server-capabilities #:client-notification-handler)
  (:import-from #:mcp-lisp/src/client/operations
                #:list-tools #:call-tool #:list-resources #:list-prompts)
  (:import-from #:mcp-lisp/src/json #:make-ht #:encode-json))

(in-package #:conformance-client)

(defun get-server-url ()
  "Extract server URL from command-line args (last argument)."
  (let ((args (uiop:command-line-arguments)))
    (car (last args))))

(defun run ()
  (let ((url (get-server-url)))
    (unless url
      (format *error-output* "Usage: sbcl --load conformance-client.lisp <server-url>~%")
      (sb-ext:exit :code 1))
    (format *error-output* "Connecting to ~a~%" url)
    (let ((client (make-http-client url)))
      (handler-case
          (unwind-protect
               (progn
                 (client-connect client)
                 ;; Initialize
                 (let ((result (client-initialize client)))
                   (format *error-output* "Initialized: protocol=~a~%"
                           (gethash "protocolVersion" result)))
                 ;; Determine scenario from env
                 (let ((scenario (uiop:getenv "MCP_CONFORMANCE_SCENARIO")))
                   (format *error-output* "Scenario: ~a~%" scenario)
                   (cond
                     ;; initialize — just connecting and initializing is enough
                     ((or (null scenario) (string= scenario "initialize"))
                      t)
                     ;; tools_call — list tools, then call the first one
                     ((string= scenario "tools_call")
                      (let ((tools (list-tools client)))
                        (format *error-output* "Found ~a tools~%" (length tools))
                        (when tools
                          (let* ((tool (first tools))
                                 (name (gethash "name" tool))
                                 (schema (gethash "inputSchema" tool))
                                 (required (when schema
                                             (let ((r (gethash "required" schema)))
                                               (when r (coerce r 'list))))))
                            (format *error-output* "Calling tool: ~a~%" name)
                            ;; Build minimal args for required params
                            (let ((args (make-hash-table :test #'equal)))
                              (dolist (req required)
                                (setf (gethash req args) "test"))
                              (let ((result (client-call client "tools/call"
                                                        (make-ht "name" name "arguments" args))))
                                (format *error-output* "Result: ~a~%"
                                        (not (null (gethash "content" result))))))))))
                     (t
                      (format *error-output* "Unknown scenario: ~a, doing basic handshake only~%" scenario)))))
            (handler-case (client-shutdown client)
              (error () nil)))
        (#+sbcl sb-sys:interactive-interrupt #-sbcl condition ()
          (format *error-output* "~%Interrupted.~%")
          (handler-case (client-shutdown client) (error () nil))))))
  (sb-ext:exit :code 0))

(run)

;;;; src/server/server.lisp
;;;;
;;;; MCP Server class using jsonrpc library.

(defpackage #:mcp-lisp/src/server/server
  (:use #:cl)
  (:import-from #:jsonrpc)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/server/state
                #:server-session
                #:make-session
                #:session-initialized-p)
  (:import-from #:mcp-lisp/src/server/lifecycle
                #:handle-initialize
                #:handle-initialized)
  (:import-from #:mcp-lisp/src/server/dispatcher
                #:handle-tools-list-result
                #:handle-tools-call-result
                #:handle-prompts-list-result
                #:handle-prompts-get-result
                #:handle-resources-list-result
                #:handle-resources-read-result
                #:handle-resources-templates-list-result)
  (:import-from #:mcp-lisp/src/primitives/tools/registry
                #:*global-tool-registry*)
  (:import-from #:mcp-lisp/src/primitives/prompts/registry
                #:*global-prompt-registry*)
  (:import-from #:mcp-lisp/src/primitives/resources/registry
                #:*global-resource-registry*)
  (:import-from #:mcp-lisp/src/server/logging
                #:handle-logging-set-level)
  (:import-from #:mcp-lisp/src/transport/mcp-stdio
                #:mcp-server-loop)
  (:import-from #:mcp-lisp/src/transport/mcp-sse
                #:start-sse-server
                #:stop-sse-server)
  (:export #:mcp-server
           #:make-server
           #:server-name
           #:server-version
           #:server-jsonrpc
           #:server-session
           #:server-tool-registry
           #:server-prompt-registry
           #:server-resource-registry
           #:server-capabilities
           #:server-start
           #:server-stop
           #:run-server))

(in-package #:mcp-lisp/src/server/server)

(defclass mcp-server ()
  ((name :initarg :name
         :initform "mcp-lisp-server"
         :reader server-name)
   (version :initarg :version
            :initform "1.0.0"
            :reader server-version)
   (jsonrpc-server :initform nil
                   :accessor server-jsonrpc)
   (session :initform nil
            :accessor server-session)
   (tool-registry :initarg :tool-registry
                  :initform nil
                  :accessor server-tool-registry)
   (prompt-registry :initarg :prompt-registry
                    :initform nil
                    :accessor server-prompt-registry)
   (resource-registry :initarg :resource-registry
                      :initform nil
                      :accessor server-resource-registry)
   (capabilities :initarg :capabilities
                 :initform nil
                 :accessor server-capabilities))
  (:documentation "MCP server instance."))

(defgeneric server-start (server &key transport)
  (:documentation "Start the MCP server with the specified transport."))

(defgeneric server-stop (server)
  (:documentation "Stop the MCP server."))

(defun make-server (&key (name "mcp-lisp-server") (version "1.0.0") tool-registry prompt-registry resource-registry)
  "Create a new MCP server instance."
  (make-instance 'mcp-server
                 :name name
                 :version version
                 :tool-registry tool-registry
                 :prompt-registry prompt-registry
                 :resource-registry resource-registry))

(defun effective-tool-registry (server)
  (or (server-tool-registry server) *global-tool-registry*))

(defun effective-prompt-registry (server)
  (or (server-prompt-registry server) *global-prompt-registry*))

(defun effective-resource-registry (server)
  (or (server-resource-registry server) *global-resource-registry*))

(defun default-capabilities ()
  (make-ht "tools" (make-ht)
           "prompts" (make-ht)
           "resources" (make-ht)))

(defun setup-jsonrpc-handlers (server)
  "Register MCP methods with the jsonrpc server."
  (let ((rpc (server-jsonrpc server))
        (session (server-session server))
        (tool-registry (effective-tool-registry server))
        (prompt-registry (effective-prompt-registry server))
        (resource-registry (effective-resource-registry server))
        (caps (or (server-capabilities server) (default-capabilities))))

    ;; initialize
    (jsonrpc:expose rpc "initialize"
                    (lambda (params)
                      (multiple-value-bind (result error-data)
                          (handle-initialize session
                                             (server-name server)
                                             (server-version server)
                                             caps
                                             params)
                        (if result
                            result
                            (error 'jsonrpc:jsonrpc-error
                                   :code (gethash "code" error-data)
                                   :message (gethash "message" error-data))))))

    ;; ping
    (jsonrpc:expose rpc "ping"
                    (lambda (params)
                      (declare (ignore params))
                      (make-ht)))

    ;; tools/list
    (jsonrpc:expose rpc "tools/list"
                    (lambda (params)
                      (declare (ignore params))
                      (handle-tools-list-result tool-registry)))

    ;; tools/call
    (jsonrpc:expose rpc "tools/call"
                    (lambda (params)
                      (handle-tools-call-result params server session tool-registry)))

    ;; prompts/list
    (jsonrpc:expose rpc "prompts/list"
                    (lambda (params)
                      (declare (ignore params))
                      (handle-prompts-list-result prompt-registry)))

    ;; prompts/get
    (jsonrpc:expose rpc "prompts/get"
                    (lambda (params)
                      (handle-prompts-get-result params server session prompt-registry)))

    ;; resources/list
    (jsonrpc:expose rpc "resources/list"
                    (lambda (params)
                      (declare (ignore params))
                      (handle-resources-list-result resource-registry)))

    ;; resources/read
    (jsonrpc:expose rpc "resources/read"
                    (lambda (params)
                      (handle-resources-read-result params server session resource-registry)))

    ;; resources/templates/list
    (jsonrpc:expose rpc "resources/templates/list"
                    (lambda (params)
                      (declare (ignore params))
                      (handle-resources-templates-list-result resource-registry)))

    ;; logging/setLevel
    (jsonrpc:expose rpc "logging/setLevel"
                    (lambda (params)
                      (handle-logging-set-level params)))

    ;; notifications/initialized
    (jsonrpc:expose rpc "notifications/initialized"
                    (lambda (params)
                      (declare (ignore params))
                      (handle-initialized session)
                      nil))))

(defmethod server-start ((server mcp-server) &key (transport :stdio))
  "Start the server."
  (setf (server-jsonrpc server) (jsonrpc:make-server))
  (setf (server-session server) (make-session))
  (setup-jsonrpc-handlers server)
  (jsonrpc:server-listen (server-jsonrpc server) :mode transport))

(defmethod server-stop ((server mcp-server))
  "Stop the server."
  (declare (ignore server)))

(defun run-server (&key (name "mcp-lisp-server") (version "1.0.0") (transport :stdio) (port 8080))
  "Create and start an MCP server in one call.
TRANSPORT options:
  :mcp-stdio - MCP protocol over stdio (newline-delimited JSON) - for Claude Code
  :sse       - MCP protocol over HTTP/SSE on PORT - for persistent servers
  :stdio     - LSP-style (Content-Length headers)"
  (let ((server (make-server :name name :version version)))
    (case transport
      (:mcp-stdio (server-start-mcp server))
      (:sse (server-start-sse server :port port))
      (otherwise (server-start server :transport transport)))))

(defun setup-mcp-handlers (server handlers)
  "Set up MCP handlers hash-table for the server."
  (let ((session (server-session server))
        (tool-registry (effective-tool-registry server))
        (prompt-registry (effective-prompt-registry server))
        (resource-registry (effective-resource-registry server))
        (caps (or (server-capabilities server) (default-capabilities))))

    (setf (gethash "initialize" handlers)
          (lambda (params)
            (multiple-value-bind (result error-data)
                (handle-initialize session
                                   (server-name server)
                                   (server-version server)
                                   caps
                                   params)
              (or result
                  (error (gethash "message" error-data))))))

    (setf (gethash "ping" handlers)
          (lambda (params)
            (declare (ignore params))
            (make-ht)))

    (setf (gethash "tools/list" handlers)
          (lambda (params)
            (declare (ignore params))
            (handle-tools-list-result tool-registry)))

    (setf (gethash "tools/call" handlers)
          (lambda (params)
            (handle-tools-call-result params server session tool-registry)))

    (setf (gethash "prompts/list" handlers)
          (lambda (params)
            (declare (ignore params))
            (handle-prompts-list-result prompt-registry)))

    (setf (gethash "prompts/get" handlers)
          (lambda (params)
            (handle-prompts-get-result params server session prompt-registry)))

    (setf (gethash "resources/list" handlers)
          (lambda (params)
            (declare (ignore params))
            (handle-resources-list-result resource-registry)))

    (setf (gethash "resources/read" handlers)
          (lambda (params)
            (handle-resources-read-result params server session resource-registry)))

    (setf (gethash "resources/templates/list" handlers)
          (lambda (params)
            (declare (ignore params))
            (handle-resources-templates-list-result resource-registry)))

    (setf (gethash "logging/setLevel" handlers)
          (lambda (params)
            (handle-logging-set-level params)))

    (setf (gethash "notifications/initialized" handlers)
          (lambda (params)
            (declare (ignore params))
            (handle-initialized session)
            nil))))

(defun server-start-mcp (server)
  "Start server using MCP stdio transport (newline-delimited JSON)."
  (setf (server-session server) (make-session))
  (let ((handlers (make-hash-table :test #'equal)))
    (setup-mcp-handlers server handlers)
    (mcp-server-loop handlers)))

(defun server-start-sse (server &key (port 8080))
  "Start server using MCP SSE transport (HTTP/SSE)."
  (setf (server-session server) (make-session))
  (let ((handlers (make-hash-table :test #'equal)))
    (setup-mcp-handlers server handlers)
    (start-sse-server handlers :port port)))

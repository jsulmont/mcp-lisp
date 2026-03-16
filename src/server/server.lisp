;;;; src/server/server.lisp
;;;;
;;;; MCP Server class using newline-delimited JSON transport.

(defpackage #:mcp-lisp/src/server/server
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/server/state
                #:server-session
                #:make-session
                #:*current-session*
                #:session-initialized-p
                #:session-subscribe
                #:session-unsubscribe)
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
  (:import-from #:mcp-lisp/src/conditions
                #:protocol-error)
  (:import-from #:mcp-lisp/src/transport/mcp-stdio
                #:mcp-server-loop)
  (:import-from #:mcp-lisp/src/transport/mcp-sse
                #:start-sse-server
                #:stop-sse-server)
  (:export #:mcp-server
           #:make-server
           #:server-name
           #:server-version
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
                 :accessor server-capabilities)
   (sse-server :initform nil
               :accessor server-sse))
  (:documentation "MCP server instance."))

(defgeneric server-start (server &key transport port)
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
  (make-ht "tools" (make-ht "listChanged" t)
           "prompts" (make-ht "listChanged" t)
           "resources" (make-ht "listChanged" t
                                "subscribe" t)
           "completions" (make-ht)
           "logging" (make-ht)))

(defun setup-handlers (server handlers)
  "Set up MCP handlers hash-table for the server.
Handlers read the active session from *current-session* (bound per-request
by the transport layer), so they work correctly with multiple concurrent sessions."
  (let ((tool-registry (effective-tool-registry server))
        (prompt-registry (effective-prompt-registry server))
        (resource-registry (effective-resource-registry server))
        (caps (or (server-capabilities server) (default-capabilities))))

    (setf (gethash "initialize" handlers)
          (lambda (params)
            (multiple-value-bind (result error-data)
                (handle-initialize *current-session*
                                   (server-name server)
                                   (server-version server)
                                   caps
                                   params)
              (or result
                  (error 'protocol-error
                         :code (gethash "code" error-data)
                         :message (gethash "message" error-data)
                         :data (gethash "data" error-data))))))

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
            (handle-tools-call-result params server *current-session* tool-registry)))

    (setf (gethash "prompts/list" handlers)
          (lambda (params)
            (declare (ignore params))
            (handle-prompts-list-result prompt-registry)))

    (setf (gethash "prompts/get" handlers)
          (lambda (params)
            (handle-prompts-get-result params server *current-session* prompt-registry)))

    (setf (gethash "resources/list" handlers)
          (lambda (params)
            (declare (ignore params))
            (handle-resources-list-result resource-registry)))

    (setf (gethash "resources/read" handlers)
          (lambda (params)
            (handle-resources-read-result params server *current-session* resource-registry)))

    (setf (gethash "resources/templates/list" handlers)
          (lambda (params)
            (declare (ignore params))
            (handle-resources-templates-list-result resource-registry)))

    (setf (gethash "completion/complete" handlers)
          (lambda (params)
            ;; Default: return empty completions. Servers can override via capabilities.
            (declare (ignore params))
            (make-ht "completion" (make-ht "values" #()))))

    (setf (gethash "resources/subscribe" handlers)
          (lambda (params)
            (let ((uri (and params (gethash "uri" params))))
              (when uri
                (session-subscribe *current-session* uri))
              (make-ht))))

    (setf (gethash "resources/unsubscribe" handlers)
          (lambda (params)
            (let ((uri (and params (gethash "uri" params))))
              (when uri
                (session-unsubscribe *current-session* uri))
              (make-ht))))

    (setf (gethash "logging/setLevel" handlers)
          (lambda (params)
            (handle-logging-set-level params)))

    (setf (gethash "notifications/initialized" handlers)
          (lambda (params)
            (declare (ignore params))
            (handle-initialized *current-session*)
            nil))))

(defmethod server-start ((server mcp-server) &key (transport :stdio) (port 8080))
  "Start the server with the specified transport.
TRANSPORT options:
  :stdio - MCP protocol over stdio (newline-delimited JSON) - default
  :sse   - Streamable HTTP on PORT (MCP 2025-03-26+)"
  (let ((handlers (make-hash-table :test #'equal)))
    (setup-handlers server handlers)
    (case transport
      (:sse
       (setf (server-sse server)
             (start-sse-server handlers :port port :session-factory #'make-session)))
      (otherwise
       (setf (server-session server) (make-session))
       (let ((*current-session* (server-session server)))
         (mcp-server-loop handlers))))))

(defmethod server-stop ((server mcp-server))
  "Stop the server."
  (when (server-sse server)
    (stop-sse-server)
    (setf (server-sse server) nil)))

(defun run-server (&key (name "mcp-lisp-server") (version "1.0.0") (transport :stdio) (port 8080))
  "Create and start an MCP server in one call.
TRANSPORT options:
  :stdio - MCP protocol over stdio (newline-delimited JSON) - for Claude Code
  :sse   - Streamable HTTP on PORT - for persistent servers"
  (let ((server (make-server :name name :version version)))
    (server-start server :transport transport :port port)))

;;;; src/client/client.lisp
;;;;
;;;; MCP Client — transport-agnostic via CLOS dispatch.

(defpackage #:mcp-lisp/src/client/client
  (:use #:cl)
  (:import-from #:mcp-lisp/src/core
                #:+protocol-version+)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:mcp-error)
  (:import-from #:mcp-lisp/src/transport/protocol
                #:transport-start
                #:transport-stop
                #:transport-call
                #:transport-notify
                #:transport-running-p
                #:transport-notification-handler)
  (:import-from #:mcp-lisp/src/transport/mcp-client
                #:stdio-transport
                #:make-stdio-transport)
  (:import-from #:mcp-lisp/src/transport/mcp-http-client
                #:http-transport
                #:make-http-transport)
  (:export #:mcp-client
           #:make-client
           #:make-http-client
           #:client-name
           #:client-version
           #:client-server-info
           #:client-server-capabilities
           #:client-protocol-version
           #:client-connected-p
           #:client-connect
           #:client-disconnect
           #:client-initialize
           #:client-shutdown
           #:client-call
           #:client-notify
           #:client-notification-handler
           #:with-client))

(in-package #:mcp-lisp/src/client/client)

(defclass mcp-client ()
  ((name :initarg :name
         :initform "mcp-lisp-client"
         :reader client-name)
   (version :initarg :version
            :initform "1.0.0"
            :reader client-version)
   (transport :initarg :transport
              :initform nil
              :accessor client-transport)
   ;; Protocol state
   (server-info :initform nil
                :accessor client-server-info)
   (server-capabilities :initform nil
                        :accessor client-server-capabilities)
   (protocol-version :initform nil
                     :accessor client-protocol-version)
   (initialized-p :initform nil
                  :accessor client-initialized-p))
  (:documentation "MCP client — transport-agnostic."))

;;; Constructors

(defun make-client (command &rest args)
  "Create an MCP client that will spawn COMMAND with ARGS (stdio transport)."
  (make-instance 'mcp-client
                 :transport (make-stdio-transport (cons command args))))

(defun make-http-client (url)
  "Create an MCP client that connects to URL (Streamable HTTP transport)."
  (make-instance 'mcp-client
                 :transport (make-http-transport url)))

;;; Connection

(defun client-connected-p (client)
  "Return T if client is connected."
  (let ((transport (client-transport client)))
    (and transport (transport-running-p transport))))

(defmethod client-connect ((client mcp-client))
  "Connect to the MCP server by starting the transport."
  (transport-start (client-transport client))
  client)

(defmethod client-disconnect ((client mcp-client))
  "Disconnect from the MCP server."
  (when (client-transport client)
    (handler-case (transport-stop (client-transport client))
      (error (e) (log:debug "Transport stop error: ~a" e))))
  (setf (client-initialized-p client) nil)
  client)

;;; RPC

(defmethod client-call ((client mcp-client) method params &key (timeout 30))
  "Make a JSON-RPC call."
  (unless (client-connected-p client)
    (error 'mcp-error :message "Client not connected"))
  (transport-call (client-transport client) method params :timeout timeout))

(defmethod client-notify ((client mcp-client) method &optional params)
  "Send a notification."
  (unless (client-connected-p client)
    (error 'mcp-error :message "Client not connected"))
  (transport-notify (client-transport client) method params))

(defun client-notification-handler (client)
  "Get the notification handler for CLIENT."
  (when (client-transport client)
    (transport-notification-handler (client-transport client))))

(defun (setf client-notification-handler) (handler client)
  "Set the notification handler for CLIENT."
  (unless (client-connected-p client)
    (error 'mcp-error :message "Client not connected"))
  (setf (transport-notification-handler (client-transport client)) handler))

;;; Lifecycle

(defmethod client-initialize ((client mcp-client))
  "Perform MCP initialize handshake."
  (let* ((params (make-ht "protocolVersion" +protocol-version+
                          "capabilities" (make-ht)
                          "clientInfo" (make-ht "name" (client-name client)
                                                "version" (client-version client))))
         (result (client-call client "initialize" params)))
    (setf (client-protocol-version client) (gethash "protocolVersion" result))
    (setf (client-server-info client) (gethash "serverInfo" result))
    (setf (client-server-capabilities client) (gethash "capabilities" result))
    (client-notify client "notifications/initialized")
    (setf (client-initialized-p client) t)
    result))

(defmethod client-shutdown ((client mcp-client))
  "Gracefully shutdown."
  (when (client-initialized-p client)
    (handler-case (client-notify client "notifications/cancelled")
      (error (e) (log:debug "Shutdown notify error: ~a" e))))
  (client-disconnect client))

(defmacro with-client ((var command &rest args) &body body)
  "Execute BODY with VAR bound to a connected, initialized client.
COMMAND can be a server command (stdio) or a URL string (HTTP)."
  (let ((cmd (gensym "CMD")))
    `(let* ((,cmd ,command)
            (,var (if (and (stringp ,cmd)
                           (or (search "http://" ,cmd)
                               (search "https://" ,cmd)))
                      (make-http-client ,cmd)
                      (make-client ,cmd ,@args))))
       (unwind-protect
            (progn
              (client-connect ,var)
              (client-initialize ,var)
              ,@body)
         (client-shutdown ,var)))))

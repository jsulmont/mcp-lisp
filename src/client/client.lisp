;;;; src/client/client.lisp
;;;;
;;;; MCP Client — supports both stdio (subprocess) and HTTP transports.

(defpackage #:mcp-lisp/src/client/client
  (:use #:cl)
  (:import-from #:mcp-lisp/src/core
                #:+protocol-version+)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:mcp-error)
  (:import-from #:mcp-lisp/src/transport/mcp-client
                #:mcp-transport
                #:make-transport
                #:transport-start
                #:transport-stop
                #:transport-call
                #:transport-notify
                #:transport-running-p
                #:transport-notification-handler)
  (:import-from #:mcp-lisp/src/transport/mcp-http-client
                #:http-transport
                #:make-http-transport
                #:http-transport-start
                #:http-transport-stop
                #:http-transport-call
                #:http-transport-notify
                #:http-transport-running-p
                #:http-transport-notification-handler)
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
   ;; stdio transport
   (command :initarg :command
            :initform nil
            :accessor client-command)
   (process :initform nil
            :accessor client-process)
   (transport :initform nil
              :accessor client-transport)
   ;; HTTP transport
   (url :initarg :url
        :initform nil
        :accessor client-url)
   (http-transport :initform nil
                   :accessor client-http-transport)
   ;; Protocol state
   (server-info :initform nil
                :accessor client-server-info)
   (server-capabilities :initform nil
                        :accessor client-server-capabilities)
   (protocol-version :initform nil
                     :accessor client-protocol-version)
   (initialized-p :initform nil
                  :accessor client-initialized-p))
  (:documentation "MCP client supporting stdio and HTTP transports."))

(defun http-client-p (client)
  (not (null (client-url client))))

(defgeneric client-connect (client)
  (:documentation "Connect to the MCP server."))

(defgeneric client-disconnect (client)
  (:documentation "Disconnect from the MCP server."))

(defgeneric client-call (client method params &key timeout)
  (:documentation "Make a JSON-RPC call to the server."))

(defgeneric client-notify (client method &optional params)
  (:documentation "Send a notification to the server."))

(defgeneric client-initialize (client)
  (:documentation "Perform the MCP initialize handshake."))

(defgeneric client-shutdown (client)
  (:documentation "Gracefully shutdown the client connection."))

;;; Constructors

(defun make-client (command &rest args)
  "Create an MCP client that will spawn COMMAND with ARGS (stdio transport)."
  (make-instance 'mcp-client :command (cons command args)))

(defun make-http-client (url)
  "Create an MCP client that connects to URL (Streamable HTTP transport)."
  (make-instance 'mcp-client :url url))

;;; Connection

(defun client-connected-p (client)
  "Return T if client is connected."
  (if (http-client-p client)
      (and (client-http-transport client)
           (http-transport-running-p (client-http-transport client)))
      (and (client-process client)
           (uiop:process-alive-p (client-process client))
           (client-transport client)
           (transport-running-p (client-transport client)))))

(defmethod client-connect ((client mcp-client))
  "Connect to the MCP server."
  (if (http-client-p client)
      ;; HTTP transport
      (let ((transport (make-http-transport (client-url client))))
        (setf (client-http-transport client) transport)
        (http-transport-start transport))
      ;; Stdio transport
      (let* ((command (client-command client))
             (process (uiop:launch-program command
                                           :input :stream
                                           :output :stream
                                           :error-output :interactive)))
        (setf (client-process client) process)
        (let ((transport (make-transport
                          (uiop:process-info-output process)
                          (uiop:process-info-input process))))
          (setf (client-transport client) transport)
          (transport-start transport))))
  client)

(defmethod client-disconnect ((client mcp-client))
  "Disconnect from the MCP server."
  (if (http-client-p client)
      ;; HTTP transport
      (when (client-http-transport client)
        (handler-case (http-transport-stop (client-http-transport client))
          (error (e) (log:debug "HTTP transport stop error: ~a" e)))
        (setf (client-http-transport client) nil))
      ;; Stdio transport
      (progn
        (when (client-transport client)
          (handler-case (transport-stop (client-transport client))
            (error (e) (log:debug "Transport stop error: ~a" e)))
          (setf (client-transport client) nil))
        (when (client-process client)
          (handler-case (uiop:terminate-process (client-process client))
            (error (e) (log:debug "Process terminate error: ~a" e)))
          (handler-case (uiop:wait-process (client-process client))
            (error (e) (log:debug "Process wait error: ~a" e)))
          (setf (client-process client) nil))))
  (setf (client-initialized-p client) nil)
  client)

(defmethod client-call ((client mcp-client) method params &key (timeout 30))
  "Make a JSON-RPC call."
  (unless (client-connected-p client)
    (error 'mcp-error :message "Client not connected"))
  (if (http-client-p client)
      (http-transport-call (client-http-transport client) method params :timeout timeout)
      (transport-call (client-transport client) method params :timeout timeout)))

(defmethod client-notify ((client mcp-client) method &optional params)
  "Send a notification."
  (unless (client-connected-p client)
    (error 'mcp-error :message "Client not connected"))
  (if (http-client-p client)
      (http-transport-notify (client-http-transport client) method params)
      (transport-notify (client-transport client) method params)))

(defun client-notification-handler (client)
  "Get the notification handler for CLIENT."
  (if (http-client-p client)
      (when (client-http-transport client)
        (http-transport-notification-handler (client-http-transport client)))
      (when (client-transport client)
        (transport-notification-handler (client-transport client)))))

(defun (setf client-notification-handler) (handler client)
  "Set the notification handler for CLIENT."
  (if (http-client-p client)
      (progn
        (unless (client-http-transport client)
          (error 'mcp-error :message "Client not connected"))
        (setf (http-transport-notification-handler (client-http-transport client)) handler))
      (progn
        (unless (client-transport client)
          (error 'mcp-error :message "Client not connected"))
        (setf (transport-notification-handler (client-transport client)) handler))))

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
  `(let ((,var (if (and (stringp ,command)
                        (or (search "http://" ,command)
                            (search "https://" ,command)))
                   (make-http-client ,command)
                   (make-client ,command ,@args))))
     (unwind-protect
          (progn
            (client-connect ,var)
            (client-initialize ,var)
            ,@body)
       (client-shutdown ,var))))

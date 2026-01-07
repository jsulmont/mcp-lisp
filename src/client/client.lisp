;;;; src/client/client.lisp
;;;;
;;;; MCP Client class using newline-delimited JSON transport.

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
                #:transport-running-p)
  (:export #:mcp-client
           #:make-client
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
           #:with-client))

(in-package #:mcp-lisp/src/client/client)

(defclass mcp-client ()
  ((name :initarg :name
         :initform "mcp-lisp-client"
         :reader client-name)
   (version :initarg :version
            :initform "1.0.0"
            :reader client-version)
   (command :initarg :command
            :accessor client-command
            :documentation "Command and args to spawn.")
   (process :initform nil
            :accessor client-process
            :documentation "The subprocess.")
   (transport :initform nil
              :accessor client-transport
              :documentation "The MCP transport instance.")
   (server-info :initform nil
                :accessor client-server-info)
   (server-capabilities :initform nil
                        :accessor client-server-capabilities)
   (protocol-version :initform nil
                     :accessor client-protocol-version)
   (initialized-p :initform nil
                  :accessor client-initialized-p))
  (:documentation "MCP client for connecting to MCP servers."))

(defgeneric client-connect (client)
  (:documentation "Spawn subprocess and connect to the MCP server."))

(defgeneric client-disconnect (client)
  (:documentation "Disconnect and terminate the subprocess."))

(defgeneric client-call (client method params &key timeout)
  (:documentation "Make a JSON-RPC call to the server."))

(defgeneric client-notify (client method &optional params)
  (:documentation "Send a notification to the server."))

(defgeneric client-initialize (client)
  (:documentation "Perform the MCP initialize handshake."))

(defgeneric client-shutdown (client)
  (:documentation "Gracefully shutdown the client connection."))

(defun make-client (command &rest args)
  "Create an MCP client that will spawn COMMAND with ARGS."
  (make-instance 'mcp-client
                 :command (cons command args)))

(defun client-connected-p (client)
  "Return T if client is connected."
  (and (client-process client)
       (uiop:process-alive-p (client-process client))
       (client-transport client)
       (transport-running-p (client-transport client))))

(defmethod client-connect ((client mcp-client))
  "Spawn subprocess and connect via MCP transport."
  (let* ((command (client-command client))
         (process (uiop:launch-program command
                                       :input :stream
                                       :output :stream
                                       :error-output :stream)))
    (setf (client-process client) process)
    (let ((transport (make-transport
                      (uiop:process-info-output process)
                      (uiop:process-info-input process))))
      (setf (client-transport client) transport)
      (transport-start transport)))
  client)

(defmethod client-disconnect ((client mcp-client))
  "Disconnect and terminate subprocess."
  (when (client-transport client)
    (handler-case (transport-stop (client-transport client))
      (error (e) (log:debug "Transport stop error: ~a" e)))
    (setf (client-transport client) nil))
  (when (client-process client)
    (handler-case (uiop:terminate-process (client-process client))
      (error (e) (log:debug "Process terminate error: ~a" e)))
    (handler-case (uiop:wait-process (client-process client))
      (error (e) (log:debug "Process wait error: ~a" e)))
    (setf (client-process client) nil))
  (setf (client-initialized-p client) nil)
  client)

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
  "Execute BODY with VAR bound to a connected, initialized client."
  `(let ((,var (make-client ,command ,@args)))
     (unwind-protect
          (progn
            (client-connect ,var)
            (client-initialize ,var)
            ,@body)
       (client-shutdown ,var))))

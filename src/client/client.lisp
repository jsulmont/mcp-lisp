;;;; src/client/client.lisp
;;;;
;;;; MCP Client class using jsonrpc library.

(defpackage #:mcp-lisp/src/client/client
  (:use #:cl)
  (:import-from #:jsonrpc)
  (:import-from #:mcp-lisp/src/core
                #:+protocol-version+)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:mcp-error)
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
   (jsonrpc-client :initform nil
                   :accessor client-jsonrpc
                   :documentation "The jsonrpc client instance.")
   (server-info :initform nil
                :accessor client-server-info)
   (server-capabilities :initform nil
                        :accessor client-server-capabilities)
   (protocol-version :initform nil
                     :accessor client-protocol-version)
   (initialized-p :initform nil
                  :accessor client-initialized-p))
  (:documentation "MCP client for connecting to MCP servers."))

(defun make-client (command &rest args)
  "Create an MCP client that will spawn COMMAND with ARGS."
  (make-instance 'mcp-client
                 :command (cons command args)))

(defun client-connected-p (client)
  "Return T if client is connected."
  (and (client-process client)
       (uiop:process-alive-p (client-process client))))

(defmethod client-connect ((client mcp-client))
  "Spawn subprocess and connect jsonrpc client."
  (let* ((command (client-command client))
         (process (uiop:launch-program command
                                       :input :stream
                                       :output :stream
                                       :error-output :stream)))
    (setf (client-process client) process)
    (setf (client-jsonrpc client) (jsonrpc:make-client))
    (jsonrpc:client-connect (client-jsonrpc client)
                            :mode :stdio
                            :input (uiop:process-info-output process)
                            :output (uiop:process-info-input process)))
  client)

(defmethod client-disconnect ((client mcp-client))
  "Disconnect and terminate subprocess."
  (when (client-jsonrpc client)
    (ignore-errors (jsonrpc:client-disconnect (client-jsonrpc client)))
    (setf (client-jsonrpc client) nil))
  (when (client-process client)
    (ignore-errors (uiop:terminate-process (client-process client)))
    (ignore-errors (uiop:wait-process (client-process client)))
    (setf (client-process client) nil))
  (setf (client-initialized-p client) nil)
  client)

(defmethod client-call ((client mcp-client) method params &key timeout)
  "Make a JSON-RPC call."
  (unless (client-connected-p client)
    (error 'mcp-error :message "Client not connected"))
  (apply #'jsonrpc:call (client-jsonrpc client) method params
         (when timeout (list :timeout timeout))))

(defmethod client-notify ((client mcp-client) method &optional params)
  "Send a notification."
  (unless (client-connected-p client)
    (error 'mcp-error :message "Client not connected"))
  (jsonrpc:notify (client-jsonrpc client) method params))

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
    (ignore-errors (client-notify client "notifications/cancelled")))
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

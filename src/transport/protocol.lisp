;;;; src/transport/protocol.lisp
;;;;
;;;; Generic transport protocol for MCP clients.
;;;; All concrete transports (stdio, HTTP) implement these generic functions.

(defpackage #:mcp-lisp/src/transport/protocol
  (:use #:cl)
  (:export #:transport-start
           #:transport-stop
           #:transport-call
           #:transport-notify
           #:transport-running-p
           #:transport-notification-handler))

(in-package #:mcp-lisp/src/transport/protocol)

(defgeneric transport-start (transport)
  (:documentation "Start the transport. Returns the transport."))

(defgeneric transport-stop (transport)
  (:documentation "Stop the transport and clean up. Returns the transport."))

(defgeneric transport-call (transport method params &key timeout)
  (:documentation "Make a JSON-RPC call and wait for response.
Returns the result or signals an error."))

(defgeneric transport-notify (transport method &optional params)
  (:documentation "Send a JSON-RPC notification (no response expected)."))

(defgeneric transport-running-p (transport)
  (:documentation "Return T if the transport is running."))

(defgeneric (setf transport-running-p) (value transport))

(defgeneric transport-notification-handler (transport)
  (:documentation "Get the notification handler function."))

(defgeneric (setf transport-notification-handler) (handler transport)
  (:documentation "Set the notification handler — a function of (method params)."))

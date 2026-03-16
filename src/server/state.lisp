;;;; src/server/state.lisp
;;;;
;;;; Server session state management.

(defpackage #:mcp-lisp/src/server/state
  (:use #:cl)
  (:export #:server-session
           #:make-session
           #:*current-session*
           #:session-initialized-p
           #:session-client-info
           #:session-protocol-version
           #:session-client-capabilities
           #:session-subscriptions
           #:session-subscribe
           #:session-unsubscribe
           #:session-subscribed-p))

(in-package #:mcp-lisp/src/server/state)

(defclass server-session ()
  ((initialized-p :initform nil
                  :accessor session-initialized-p
                  :documentation "T after initialized notification received.")
   (client-info :initform nil
                :accessor session-client-info
                :documentation "Client info from initialize request.")
   (protocol-version :initform nil
                     :accessor session-protocol-version
                     :documentation "Negotiated protocol version.")
   (client-capabilities :initform nil
                        :accessor session-client-capabilities
                        :documentation "Client capabilities from initialize.")
   (subscriptions :initform (make-hash-table :test #'equal)
                  :accessor session-subscriptions
                  :documentation "Set of subscribed resource URIs."))
  (:documentation "Per-connection session state."))

(defun session-subscribe (session uri)
  "Subscribe to resource URI. Returns T."
  (setf (gethash uri (session-subscriptions session)) t))

(defun session-unsubscribe (session uri)
  "Unsubscribe from resource URI. Returns T if was subscribed."
  (remhash uri (session-subscriptions session)))

(defun session-subscribed-p (session uri)
  "Return T if subscribed to URI."
  (gethash uri (session-subscriptions session)))

(defvar *current-session* nil
  "The active session for the current request.
Bound per-request by the transport layer (SSE or stdio).")

(defun make-session ()
  "Create a new server session."
  (make-instance 'server-session))

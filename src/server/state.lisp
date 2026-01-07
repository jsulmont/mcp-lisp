;;;; src/server/state.lisp
;;;;
;;;; Server session state management.

(defpackage #:mcp-lisp/src/server/state
  (:use #:cl)
  (:export #:server-session
           #:make-session
           #:session-initialized-p
           #:session-client-info
           #:session-protocol-version
           #:session-client-capabilities))

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
                        :documentation "Client capabilities from initialize."))
  (:documentation "Per-connection session state."))

(defun make-session ()
  "Create a new server session."
  (make-instance 'server-session))

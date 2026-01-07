;;;; src/server/lifecycle.lisp
;;;;
;;;; MCP lifecycle handling (initialize/initialized/shutdown).

(defpackage #:mcp-lisp/src/server/lifecycle
  (:use #:cl)
  (:import-from #:mcp-lisp/src/core
                #:+protocol-version+
                #:+supported-protocol-versions+)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/server/state
                #:session-initialized-p
                #:session-client-info
                #:session-protocol-version
                #:session-client-capabilities)
  (:export #:handle-initialize
           #:handle-initialized
           #:make-initialize-result
           #:negotiate-protocol-version))

(in-package #:mcp-lisp/src/server/lifecycle)

(defun negotiate-protocol-version (client-version)
  "Negotiate protocol version with CLIENT-VERSION.
Returns the negotiated version or NIL if unsupported."
  (cond
    ((null client-version)
     (first +supported-protocol-versions+))
    ((find client-version +supported-protocol-versions+ :test #'string=)
     client-version)
    (t nil)))

(defun make-initialize-result (server-name server-version protocol-version capabilities)
  "Create the result payload for initialize response."
  (make-ht "protocolVersion" protocol-version
           "serverInfo" (make-ht "name" server-name
                                 "version" server-version)
           "capabilities" capabilities))

(defun handle-initialize (session server-name server-version capabilities params)
  "Handle initialize request. Returns (values result error-response).
On success, returns result and nil. On failure, returns nil and error-response."
  (let* ((client-version (and params (gethash "protocolVersion" params)))
         (chosen (negotiate-protocol-version client-version)))
    (if (null chosen)
        (values nil
                (make-ht "code" -32602
                         "message" (format nil "Unsupported protocol version: ~a"
                                           client-version)
                         "data" (make-ht "supportedVersions"
                                         (coerce +supported-protocol-versions+ 'vector))))
        (progn
          (setf (session-protocol-version session) chosen)
          (setf (session-client-info session)
                (and params (gethash "clientInfo" params)))
          (setf (session-client-capabilities session)
                (and params (gethash "capabilities" params)))
          (values (make-initialize-result server-name server-version
                                          chosen capabilities)
                  nil)))))

(defun handle-initialized (session)
  "Handle initialized notification."
  (setf (session-initialized-p session) t))

;;;; src/transport/mcp-client.lisp
;;;;
;;;; MCP client transport using newline-delimited JSON over stdio.

(defpackage #:mcp-lisp/src/transport/mcp-client
  (:use #:cl)
  (:import-from #:bordeaux-threads)
  (:import-from #:mcp-lisp/src/json
                #:encode-json
                #:make-ht
                #:read-json-line
                #:write-json-line)
  (:import-from #:mcp-lisp/src/conditions
                #:mcp-error
                #:protocol-error)
  (:export #:mcp-transport
           #:make-transport
           #:transport-start
           #:transport-stop
           #:transport-call
           #:transport-notify
           #:transport-running-p
           #:transport-notification-handler))

(in-package #:mcp-lisp/src/transport/mcp-client)

(defclass mcp-transport ()
  ((input :initarg :input
          :accessor transport-input
          :documentation "Input stream (read responses from server).")
   (output :initarg :output
           :accessor transport-output
           :documentation "Output stream (write requests to server).")
   (next-id :initform 0
            :accessor transport-next-id)
   (pending :initform (make-hash-table :test #'eql)
            :accessor transport-pending
            :documentation "Hash-table of pending request ID -> result cons cell.")
   (pending-lock :initform (bt:make-lock "pending-requests")
                 :accessor transport-pending-lock)
   (reader-thread :initform nil
                  :accessor transport-reader-thread)
   (running :initform nil
            :accessor transport-running-p)
   (notification-handler :initform nil
                         :accessor transport-notification-handler
                         :documentation "Function (method params) called for server notifications."))
  (:documentation "Transport for MCP client using newline-delimited JSON."))

(defun make-transport (input output)
  "Create a new MCP transport with INPUT and OUTPUT streams."
  (make-instance 'mcp-transport :input input :output output))

(defun resolve-pending (transport id result error-p)
  "Resolve a pending request with RESULT."
  (bt:with-lock-held ((transport-pending-lock transport))
    (let ((cell (gethash id (transport-pending transport))))
      (when cell
        (setf (car cell) (if error-p :error :ok))
        (setf (cdr cell) result)
        (remhash id (transport-pending transport))))))

(defun reader-loop (transport)
  "Read responses from server and dispatch to pending requests or notification handler."
  (loop while (transport-running-p transport)
        do (handler-case
               (let ((response (read-json-line (transport-input transport))))
                 (unless response
                   (setf (transport-running-p transport) nil)
                   (return))
                 (let ((id (gethash "id" response))
                       (method (gethash "method" response))
                       (params (gethash "params" response))
                       (error-obj (gethash "error" response))
                       (result (gethash "result" response)))
                   (if id
                       ;; Response to a request
                       (if error-obj
                           (resolve-pending transport id error-obj t)
                           (resolve-pending transport id result nil))
                       ;; Server-initiated notification (no id)
                       (when (and method (transport-notification-handler transport))
                         (handler-case
                             (funcall (transport-notification-handler transport)
                                      method params)
                           (error (e)
                             (log:warn "Notification handler error (~a): ~a" method e)))))))
             (error (e)
               (log:debug "Reader loop error: ~a" e)
               (setf (transport-running-p transport) nil)
               (return)))))

(defgeneric transport-start (transport)
  (:documentation "Start the transport reader thread."))

(defmethod transport-start ((transport mcp-transport))
  "Start the transport reader thread."
  (setf (transport-running-p transport) t)
  (setf (transport-reader-thread transport)
        (bt:make-thread (lambda () (reader-loop transport))
                        :name "mcp-client-reader"))
  transport)

(defgeneric transport-stop (transport)
  (:documentation "Stop the transport."))

(defmethod transport-stop ((transport mcp-transport))
  "Stop the transport and clean up."
  (setf (transport-running-p transport) nil)
  (when (transport-reader-thread transport)
    (handler-case (bt:destroy-thread (transport-reader-thread transport))
      (error (e) (log:debug "Thread destroy error: ~a" e)))
    (setf (transport-reader-thread transport) nil))
  (bt:with-lock-held ((transport-pending-lock transport))
    (clrhash (transport-pending transport)))
  transport)

(defgeneric transport-call (transport method params &key timeout)
  (:documentation "Make a JSON-RPC call and wait for response."))

(defmethod transport-call ((transport mcp-transport) method params &key (timeout 30))
  "Make a JSON-RPC call and wait for response.
Returns the result or signals an error."
  (unless (transport-running-p transport)
    (error 'mcp-error :message "Transport not running"))
  (let* ((id (bt:with-lock-held ((transport-pending-lock transport))
               (incf (transport-next-id transport))))
         (cell (cons nil nil))
         (request (make-ht "jsonrpc" "2.0"
                           "id" id
                           "method" method
                           "params" params)))
    (bt:with-lock-held ((transport-pending-lock transport))
      (setf (gethash id (transport-pending transport)) cell))
    (write-json-line request (transport-output transport))
    (let ((deadline (+ (get-internal-real-time)
                       (* timeout internal-time-units-per-second))))
      (loop
        (when (car cell)
          (if (eq (car cell) :error)
              (let ((err (cdr cell)))
                (error 'protocol-error
                       :code (gethash "code" err)
                       :message (gethash "message" err)))
              (return (cdr cell))))
        (when (> (get-internal-real-time) deadline)
          (bt:with-lock-held ((transport-pending-lock transport))
            (remhash id (transport-pending transport)))
          (error 'mcp-error :message "Request timed out"))
        (sleep 0.01)))))

(defgeneric transport-notify (transport method &optional params)
  (:documentation "Send a notification (no response expected)."))

(defmethod transport-notify ((transport mcp-transport) method &optional params)
  "Send a notification (no response expected)."
  (unless (transport-running-p transport)
    (error 'mcp-error :message "Transport not running"))
  (let ((notification (make-ht "jsonrpc" "2.0"
                               "method" method)))
    (when params
      (setf (gethash "params" notification) params))
    (write-json-line notification (transport-output transport)))
  nil)

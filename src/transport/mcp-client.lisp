;;;; src/transport/mcp-client.lisp
;;;;
;;;; MCP stdio transport — newline-delimited JSON over a subprocess.

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
  (:import-from #:mcp-lisp/src/transport/protocol
                #:transport-start
                #:transport-stop
                #:transport-call
                #:transport-notify
                #:transport-running-p
                #:transport-notification-handler)
  (:export #:stdio-transport
           #:make-stdio-transport
           #:stdio-transport-request-handler
           ;; Re-export protocol GFs so downstream can import from here
           #:transport-start
           #:transport-stop
           #:transport-call
           #:transport-notify
           #:transport-running-p
           #:transport-notification-handler))

(in-package #:mcp-lisp/src/transport/mcp-client)

;;; A pending-request bundles a lock, condition variable, and result cell.
;;; The reader thread signals the CV; the calling thread waits on it.
(defstruct pending-request
  (lock   (bt:make-lock "pending-req") :read-only t)
  (cv     (bt:make-condition-variable :name "pending-req-cv") :read-only t)
  (status nil :type (member nil :ok :error))
  (value  nil))

(defclass stdio-transport ()
  ((command :initarg :command
            :reader transport-command
            :documentation "Command list to spawn the server subprocess.")
   (process :initform nil
            :accessor transport-process
            :documentation "The subprocess (uiop process-info).")
   (input :initform nil
          :accessor transport-input
          :documentation "Input stream (read responses from server).")
   (output :initform nil
           :accessor transport-output
           :documentation "Output stream (write requests to server).")
   (output-lock :initform (bt:make-lock "stdio-output")
                :accessor transport-output-lock
                :documentation "Serializes writes to OUTPUT across concurrent callers.")
   (next-id :initform 0
            :accessor transport-next-id)
   (pending :initform (make-hash-table :test #'eql)
            :accessor transport-pending
            :documentation "Hash-table of request ID -> pending-request.")
   (pending-lock :initform (bt:make-lock "pending-requests")
                 :accessor transport-pending-lock)
   (reader-thread :initform nil
                  :accessor transport-reader-thread)
   (running :initform nil
            :accessor transport-running-p)
   (notification-handler :initform nil
                         :accessor transport-notification-handler
                         :documentation "Function (method params) called for server notifications.")
   (request-handler :initform nil
                    :accessor stdio-transport-request-handler
                    :documentation "Function (method params) -> result for server-initiated
requests (sampling/createMessage, elicitation/create, ...). Each request is handled on
its own thread so a slow handler never stalls the reader loop."))
  (:documentation "MCP client transport over stdio with a subprocess."))

(defun make-stdio-transport (command)
  "Create a stdio transport. COMMAND is a list of (program &rest args)."
  (make-instance 'stdio-transport :command command))

;;; --- Reader loop ---

(defun resolve-pending (transport id result error-p)
  "Resolve a pending request — set result and signal the waiting thread."
  (let ((req nil))
    (bt:with-lock-held ((transport-pending-lock transport))
      (setf req (gethash id (transport-pending transport)))
      (when req
        (remhash id (transport-pending transport))))
    (when req
      (bt:with-lock-held ((pending-request-lock req))
        (setf (pending-request-status req) (if error-p :error :ok)
              (pending-request-value req) result)
        (bt:condition-notify (pending-request-cv req))))))

(defun resolve-all-pending (transport message)
  "Fail every in-flight request with MESSAGE — used when the connection drops.
Without this, waiters block until their per-call timeout instead of failing fast."
  (let ((reqs nil))
    (bt:with-lock-held ((transport-pending-lock transport))
      (maphash (lambda (id req) (declare (ignore id)) (push req reqs))
               (transport-pending transport))
      (clrhash (transport-pending transport)))
    (dolist (req reqs)
      (bt:with-lock-held ((pending-request-lock req))
        (setf (pending-request-status req) :error
              (pending-request-value req) (make-ht "code" -32000 "message" message))
        (bt:condition-notify (pending-request-cv req))))))

(defun write-server-response (transport id result &key error-msg)
  "Write a JSON-RPC response to a server-initiated request back to the server."
  (let ((resp (if error-msg
                  (make-ht "jsonrpc" "2.0" "id" id
                           "error" (make-ht "code" -32603 "message" error-msg))
                  (make-ht "jsonrpc" "2.0" "id" id "result" result))))
    (handler-case
        (bt:with-lock-held ((transport-output-lock transport))
          (write-json-line resp (transport-output transport)))
      (error (e) (log:warn "Failed to write response for ~a: ~a" id e)))))

(defun handle-server-request (transport id method params)
  "Run the request handler for a server-initiated request on its own thread and
write the response back. Threading keeps a slow handler (e.g. an LLM call for
sampling) from blocking the reader loop."
  (let ((handler (stdio-transport-request-handler transport)))
    (if handler
        (bt:make-thread
         (lambda ()
           (handler-case
               (write-server-response transport id (funcall handler method params))
             (error (e)
               (write-server-response transport id nil :error-msg (princ-to-string e)))))
         :name "mcp-client-server-request")
        (write-server-response transport id nil
                               :error-msg (format nil "No handler for server request: ~a" method)))))

(defun reader-loop (transport)
  "Read messages from the server and dispatch: responses to pending requests,
server-initiated requests to the request handler, notifications to the handler."
  (loop while (transport-running-p transport)
        do (handler-case
               (let ((response (read-json-line (transport-input transport))))
                 (unless response
                   (setf (transport-running-p transport) nil)
                   (resolve-all-pending transport "Connection closed by server (EOF)")
                   (return))
                 (let ((id (gethash "id" response))
                       (method (gethash "method" response))
                       (params (gethash "params" response))
                       (error-obj (gethash "error" response)))
                   (cond
                     ;; Server-initiated request — has both method and id.
                     ((and method id)
                      (handle-server-request transport id method params))
                     ;; Response to one of our requests — has id, no method.
                     (id
                      (if error-obj
                          (resolve-pending transport id error-obj t)
                          (resolve-pending transport id (gethash "result" response) nil)))
                     ;; Server-initiated notification — has method, no id.
                     ((and method (transport-notification-handler transport))
                      (handler-case
                          (funcall (transport-notification-handler transport)
                                   method params)
                        (error (e)
                          (log:warn "Notification handler error (~a): ~a" method e)))))))
             (error (e)
               (log:warn "Reader loop terminated: ~a" e)
               (setf (transport-running-p transport) nil)
               (resolve-all-pending transport (format nil "Connection lost: ~a" e))
               (return)))))

;;; --- Protocol implementation ---

(defmethod transport-start ((transport stdio-transport))
  "Launch the subprocess and start the reader thread."
  (let* ((command (transport-command transport))
         (process (uiop:launch-program command
                                       :input :stream
                                       :output :stream
                                       :error-output :interactive)))
    (setf (transport-process transport) process
          (transport-input transport) (uiop:process-info-output process)
          (transport-output transport) (uiop:process-info-input process)
          (transport-running-p transport) t
          (transport-reader-thread transport)
          (bt:make-thread (lambda () (reader-loop transport))
                          :name "mcp-client-reader")))
  transport)

(defmethod transport-stop ((transport stdio-transport))
  "Stop reader thread, terminate subprocess, clean up."
  (setf (transport-running-p transport) nil)
  ;; Close input to unblock the reader thread
  (when (transport-input transport)
    (ignore-errors (close (transport-input transport))))
  (when (transport-reader-thread transport)
    (ignore-errors (bt:join-thread (transport-reader-thread transport)))
    (setf (transport-reader-thread transport) nil))
  ;; Terminate subprocess
  (when (transport-process transport)
    (handler-case (uiop:terminate-process (transport-process transport))
      (error (e) (log:debug "Process terminate error: ~a" e)))
    (handler-case (uiop:wait-process (transport-process transport))
      (error (e) (log:debug "Process wait error: ~a" e)))
    (setf (transport-process transport) nil))
  (resolve-all-pending transport "Transport stopped")
  transport)

(defmethod transport-call ((transport stdio-transport) method params &key (timeout 30))
  "Make a JSON-RPC call and wait for response."
  (unless (transport-running-p transport)
    (error 'mcp-error :message "Transport not running"))
  (let* ((id (bt:with-lock-held ((transport-pending-lock transport))
               (incf (transport-next-id transport))))
         (req (make-pending-request))
         (request (make-ht "jsonrpc" "2.0"
                           "id" id
                           "method" method)))
    (when params
      (setf (gethash "params" request) params))
    ;; Register pending request
    (bt:with-lock-held ((transport-pending-lock transport))
      (setf (gethash id (transport-pending transport)) req))
    ;; Send request (lock serializes interleaving with other callers)
    (bt:with-lock-held ((transport-output-lock transport))
      (write-json-line request (transport-output transport)))
    ;; Wait for response via condition variable
    (bt:with-lock-held ((pending-request-lock req))
      (let ((deadline (+ (get-internal-real-time)
                         (* timeout internal-time-units-per-second))))
        (loop until (pending-request-status req)
              do (let ((remaining (/ (- deadline (get-internal-real-time))
                                     internal-time-units-per-second)))
                   (when (<= remaining 0)
                     (bt:with-lock-held ((transport-pending-lock transport))
                       (remhash id (transport-pending transport)))
                     (error 'mcp-error :message "Request timed out"))
                   (bt:condition-wait (pending-request-cv req)
                                      (pending-request-lock req)
                                      :timeout (min remaining 1.0))))))
    ;; Return result or signal error
    (if (eq (pending-request-status req) :error)
        (let ((err (pending-request-value req)))
          (error 'protocol-error
                 :code (gethash "code" err)
                 :message (gethash "message" err)))
        (pending-request-value req))))

(defmethod transport-notify ((transport stdio-transport) method &optional params)
  "Send a notification (no response expected)."
  (unless (transport-running-p transport)
    (error 'mcp-error :message "Transport not running"))
  (let ((notification (make-ht "jsonrpc" "2.0"
                               "method" method)))
    (when params
      (setf (gethash "params" notification) params))
    (bt:with-lock-held ((transport-output-lock transport))
      (write-json-line notification (transport-output transport))))
  nil)

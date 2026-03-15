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
           ;; Re-export protocol GFs so downstream can import from here
           #:transport-start
           #:transport-stop
           #:transport-call
           #:transport-notify
           #:transport-running-p
           #:transport-notification-handler))

(in-package #:mcp-lisp/src/transport/mcp-client)

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
  (:documentation "MCP client transport over stdio with a subprocess."))

(defun make-stdio-transport (command)
  "Create a stdio transport. COMMAND is a list of (program &rest args)."
  (make-instance 'stdio-transport :command command))

;;; --- Reader loop ---

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
                   (declare (ignore result))
                   (if id
                       ;; Response to a request
                       (if error-obj
                           (resolve-pending transport id error-obj t)
                           (resolve-pending transport id (gethash "result" response) nil))
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
  (bt:with-lock-held ((transport-pending-lock transport))
    (clrhash (transport-pending transport)))
  transport)

(defmethod transport-call ((transport stdio-transport) method params &key (timeout 30))
  "Make a JSON-RPC call and wait for response."
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

(defmethod transport-notify ((transport stdio-transport) method &optional params)
  "Send a notification (no response expected)."
  (unless (transport-running-p transport)
    (error 'mcp-error :message "Transport not running"))
  (let ((notification (make-ht "jsonrpc" "2.0"
                               "method" method)))
    (when params
      (setf (gethash "params" notification) params))
    (write-json-line notification (transport-output transport)))
  nil)

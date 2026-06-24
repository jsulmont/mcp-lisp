;;;; src/transport/mcp-stdio.lisp
;;;;
;;;; MCP stdio transport using newline-delimited JSON.
;;;;
;;;; Bidirectional: the calling thread reads stdin and demultiplexes — client
;;;; responses to server-initiated requests are routed to the waiting handler;
;;;; client requests/notifications are handed to a single worker thread (so the
;;;; reader stays free to deliver a sampling/elicitation response while a handler
;;;; awaits it). Handlers run with the tool-context channel bound, so
;;;; progress/sampling/elicitation work over stdio.

(defpackage #:mcp-lisp/src/transport/mcp-stdio
  (:use #:cl #:log4cl)
  (:import-from #:bordeaux-threads)
  (:import-from #:sb-concurrency
                #:make-mailbox
                #:send-message
                #:receive-message)
  (:import-from #:mcp-lisp/src/json
                #:encode-json
                #:make-ht
                #:read-json-line
                #:write-json-line)
  (:import-from #:mcp-lisp/src/conditions
                #:protocol-error
                #:protocol-error-code
                #:protocol-error-data
                #:mcp-error-message)
  (:import-from #:mcp-lisp/src/server/state
                #:*current-session*)
  (:import-from #:mcp-lisp/src/server/tool-context
                #:*stream-notify-fn*
                #:*stream-call-fn*)
  (:export #:run-mcp-server
           #:mcp-server-loop
           #:setup-file-logging))

(in-package #:mcp-lisp/src/transport/mcp-stdio)

(defun setup-file-logging (path &key (level :debug))
  "Configure log4cl to write to a file. Call before starting server.
LEVEL can be :debug, :info, :warn, :error (default :debug)."
  (log:config :daily path :backup nil)
  (log:config :sane2)
  (log:config level))

(defun make-response (id result)
  "Create a JSON-RPC success response."
  (make-ht "jsonrpc" "2.0" "id" id "result" result))

(defun make-error-response (id code message &optional data)
  "Create a JSON-RPC error response."
  (let ((err (make-ht "code" code "message" message)))
    (when data
      (setf (gethash "data" err) data))
    (make-ht "jsonrpc" "2.0" "id" id "error" err)))

;;; =====================================================================
;;; Server->client channel (sampling / elicitation / progress over stdio)
;;; =====================================================================

(defstruct stdio-channel
  "Per-loop state for talking back to the client."
  output
  (output-lock (bt:make-lock "stdio-output"))
  (pending (make-hash-table :test #'eql))   ; request id -> stdio-waiter
  (pending-lock (bt:make-lock "stdio-pending"))
  (next-id 0)
  (id-lock (bt:make-lock "stdio-id")))

(defstruct stdio-waiter
  (lock (bt:make-lock "stdio-waiter") :read-only t)
  (cv (bt:make-condition-variable) :read-only t)
  (status nil :type (member nil :ok :error))
  (value nil))

(defun channel-write (chan message)
  "Write MESSAGE as a JSON-RPC line, serialized against all other writers."
  (bt:with-lock-held ((stdio-channel-output-lock chan))
    (write-json-line message (stdio-channel-output chan))))

(defun channel-notify (chan method params)
  "Send a server->client notification."
  (let ((notif (make-ht "jsonrpc" "2.0" "method" method)))
    (when params
      (setf (gethash "params" notif) params))
    (channel-write chan notif)))

(defun channel-call (chan method params timeout)
  "Send a server->client request and block until the client responds (or TIMEOUT).
Returns the response result, or signals on error/timeout. The reader thread
routes the response via CHANNEL-RESOLVE, so this never blocks reading."
  (let* ((id (bt:with-lock-held ((stdio-channel-id-lock chan))
               (incf (stdio-channel-next-id chan))))
         (waiter (make-stdio-waiter))
         (req (make-ht "jsonrpc" "2.0" "id" id "method" method)))
    (when params
      (setf (gethash "params" req) params))
    (bt:with-lock-held ((stdio-channel-pending-lock chan))
      (setf (gethash id (stdio-channel-pending chan)) waiter))
    (unwind-protect
         (progn
           (channel-write chan req)
           (bt:with-lock-held ((stdio-waiter-lock waiter))
             (let ((deadline (+ (get-internal-real-time)
                                (* timeout internal-time-units-per-second))))
               (loop until (stdio-waiter-status waiter)
                     do (let ((remaining (/ (- deadline (get-internal-real-time))
                                            internal-time-units-per-second)))
                          (when (<= remaining 0)
                            (error "Timeout waiting for client response to ~a" method))
                          (bt:condition-wait (stdio-waiter-cv waiter)
                                             (stdio-waiter-lock waiter)
                                             :timeout (min remaining 1.0))))))
           (let ((response (stdio-waiter-value waiter)))
             (if (eq (stdio-waiter-status waiter) :error)
                 (let ((err (gethash "error" response)))
                   (error "Client request ~a failed: ~a"
                          method (and (hash-table-p err) (gethash "message" err))))
                 (gethash "result" response))))
      (bt:with-lock-held ((stdio-channel-pending-lock chan))
        (remhash id (stdio-channel-pending chan))))))

(defun channel-resolve (chan response)
  "Route a client RESPONSE to the server->client request waiting on its id."
  (let ((id (gethash "id" response))
        (waiter nil))
    (bt:with-lock-held ((stdio-channel-pending-lock chan))
      (setf waiter (gethash id (stdio-channel-pending chan))))
    (when waiter
      (bt:with-lock-held ((stdio-waiter-lock waiter))
        (setf (stdio-waiter-status waiter) (if (gethash "error" response) :error :ok)
              (stdio-waiter-value waiter) response)
        (bt:condition-notify (stdio-waiter-cv waiter))))))

(defun channel-resolve-all (chan message)
  "Fail every in-flight server->client request — used when stdin closes."
  (let ((waiters nil))
    (bt:with-lock-held ((stdio-channel-pending-lock chan))
      (maphash (lambda (id w) (declare (ignore id)) (push w waiters))
               (stdio-channel-pending chan))
      (clrhash (stdio-channel-pending chan)))
    (dolist (w waiters)
      (bt:with-lock-held ((stdio-waiter-lock w))
        (setf (stdio-waiter-status w) :error
              (stdio-waiter-value w) (make-ht "error" (make-ht "message" message)))
        (bt:condition-notify (stdio-waiter-cv w))))))

;;; =====================================================================
;;; Worker: processes client requests/notifications in order
;;; =====================================================================

(defun process-message (message handlers chan)
  "Run the handler for one client request/notification and write its response."
  (let* ((id (gethash "id" message))
         (method (gethash "method" message))
         (params (gethash "params" message))
         (handler (gethash method handlers)))
    (log:debug "Request: method=~a id=~a" method id)
    (cond
      ;; Notification (no id) — run handler, no response
      ((null id)
       (when handler
         (handler-case (funcall handler params)
           (error (e)
             (log:error "Notification handler error (~a): ~a" method e)))))
      ;; Request with handler
      (handler
       (handler-case
           (channel-write chan (make-response id (funcall handler params)))
         (protocol-error (e)
           (log:error "Protocol error: ~a" e)
           (channel-write chan (make-error-response id (protocol-error-code e)
                                                    (mcp-error-message e)
                                                    (protocol-error-data e))))
         (error (e)
           (log:error "Handler error: ~a" e)
           (channel-write chan (make-error-response id -32603 (princ-to-string e))))))
      ;; Unknown method
      (t
       (log:warn "Unknown method: ~a" method)
       (channel-write chan (make-error-response
                            id -32601 (format nil "Method not found: ~a" method)))))))

(defun stdio-worker (mbox handlers session chan)
  "Process queued client messages sequentially, with the tool-context channel
bound so handlers can report progress and make server->client requests."
  (let ((*current-session* session)
        (*stream-notify-fn* (lambda (m p) (channel-notify chan m p)))
        (*stream-call-fn* (lambda (m p &key (timeout 30)) (channel-call chan m p timeout))))
    (loop for message = (receive-message mbox)
          until (eq message :eof)
          do (handler-case (process-message message handlers chan)
               (error (e) (log:error "Worker error: ~a" e))))))

;;; =====================================================================
;;; Main loop: reader (calling thread) + demux
;;; =====================================================================

(defun mcp-server-loop (handlers &key (input *standard-input*) (output *standard-output*))
  "Run the MCP stdio server loop with HANDLERS mapping method names to functions.
Each handler receives (params) and returns the result or signals an error.
Blocks until stdin reaches EOF. Bidirectional: handlers may use the tool-context
helpers (progress/sampling/elicitation) — the calling thread reads and routes
client responses while a worker thread runs handlers."
  (log:info "MCP server starting")
  (let ((chan (make-stdio-channel :output output))
        (session *current-session*)
        (mbox (make-mailbox :name "mcp-stdio-requests")))
    (let ((worker (bt:make-thread
                   (lambda () (stdio-worker mbox handlers session chan))
                   :name "mcp-stdio-worker")))
      (unwind-protect
           (loop for message = (read-json-line input)
                 while message
                 do (if (and (gethash "id" message)
                             (null (gethash "method" message)))
                        ;; Response to a server->client request
                        (channel-resolve chan message)
                        ;; Client request or notification
                        (send-message mbox message))
                 finally (log:info "EOF received, shutting down"))
        ;; Shutdown: unblock any in-flight server->client call, stop the worker.
        (channel-resolve-all chan "stdin closed before client responded")
        (send-message mbox :eof)
        (ignore-errors (bt:join-thread worker))))))

(defun run-mcp-server (setup-fn &key (input *standard-input*) (output *standard-output*))
  "Run an MCP server. SETUP-FN receives a handlers hash-table to populate.
Example:
  (run-mcp-server
    (lambda (handlers)
      (setf (gethash \"initialize\" handlers) #'handle-initialize)
      (setf (gethash \"tools/list\" handlers) #'handle-tools-list)))"
  (let ((handlers (make-hash-table :test #'equal)))
    (funcall setup-fn handlers)
    (mcp-server-loop handlers :input input :output output)))

;;;; src/a2a/server.lisp
;;;;
;;;; A2A Server - HTTP endpoints for A2A protocol.
;;;; Runs on the same Woo server as MCP via *a2a-handler*.

(defpackage #:mcp-lisp/src/a2a/server
  (:use #:cl #:log4cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht
                #:encode-json
                #:decode-json)
  (:import-from #:mcp-lisp/src/a2a/agent-card
                #:*agent-card*
                #:agent-card-to-json)
  (:import-from #:mcp-lisp/src/a2a/skills
                #:*skill-registry*
                #:get-skill
                #:invoke-skill)
  (:import-from #:mcp-lisp/src/a2a/tasks
                #:create-task
                #:get-task
                #:update-task-status
                #:add-task-message
                #:add-task-artifact
                #:cancel-task
                #:task-to-ht)
  (:import-from #:mcp-lisp/src/a2a/messages
                #:make-message
                #:make-text-part
                #:message-to-ht)
  (:export #:*a2a-server*
           #:start-a2a-server
           #:stop-a2a-server
           #:handle-a2a-request))

(in-package #:mcp-lisp/src/a2a/server)

(defvar *a2a-server* nil "Non-nil when A2A handler is registered on the Woo server.")

(defun json-headers ()
  (list :content-type "application/json"
        :access-control-allow-origin "*"))

(defun json-response (status data)
  "Return a Clack response triple with JSON body."
  (list status (json-headers) (list (encode-json data))))

(defun agent-card-handler ()
  "Handle GET /.well-known/agent.json"
  (log:info "Agent card requested")
  (if *agent-card*
      (json-response 200 (mcp-lisp/src/a2a/agent-card::agent-card-to-ht *agent-card*))
      (json-response 404 (make-ht "error" "No agent card configured"))))

(defun send-message-handler (body)
  "Handle POST /a2a/message"
  (handler-case
      (let* ((request (decode-json body))
             (message-data (gethash "message" request))
             (skill-id (gethash "skillId" request)))
        (log:debug "A2A message received: skill=~a" skill-id)
        (let ((task (create-task)))
          (update-task-status task :working)
          (when message-data
            (add-task-message task message-data))
          (handler-case
              (let ((result (if skill-id
                                (invoke-skill skill-id message-data)
                                (error "No skill specified"))))
                (add-task-artifact task (make-ht "type" "text" "text" result))
                (update-task-status task :completed))
            (error (e)
              (add-task-artifact task (make-ht "type" "error" "message" (princ-to-string e)))
              (update-task-status task :failed)))
          (json-response 200 (task-to-ht task))))
    (error (e)
      (log:error "A2A message error: ~a" e)
      (json-response 400 (make-ht "error" (princ-to-string e))))))

(defun extract-task-id-from-path (path prefix)
  "Extract task ID from PATH, stripping PREFIX and any trailing segments."
  (let* ((after-prefix (subseq path (length prefix)))
         (slash-pos (position #\/ after-prefix)))
    (if slash-pos
        (subseq after-prefix 0 slash-pos)
        after-prefix)))

(defun get-task-handler (path)
  "Handle GET /a2a/task/:id"
  (let ((task-id (extract-task-id-from-path path "/a2a/task/")))
    (log:debug "Task status requested: ~a" task-id)
    (let ((task (get-task task-id)))
      (if task
          (json-response 200 (task-to-ht task))
          (json-response 404 (make-ht "error" "Task not found"))))))

(defun cancel-task-handler (path)
  "Handle POST /a2a/task/:id/cancel"
  (let ((task-id (extract-task-id-from-path path "/a2a/task/")))
    (log:debug "Task cancel requested: ~a" task-id)
    (let ((task (get-task task-id)))
      (if task
          (progn
            (cancel-task task)
            (json-response 200 (task-to-ht task)))
          (json-response 404 (make-ht "error" "Task not found"))))))

(defun handle-a2a-request (env method path body)
  "Dispatch an A2A request. Returns a Clack response triple or NIL.
Called from mcp-woo's Clack app for A2A routes."
  (declare (ignore env))
  (log:debug "A2A HTTP ~a ~a" method path)
  (cond
    ((and (eq method :get) (string= path "/.well-known/agent.json"))
     (agent-card-handler))
    ((and (eq method :post) (string= path "/a2a/message"))
     (send-message-handler body))
    ((and (eq method :post)
          (alexandria:starts-with-subseq "/a2a/task/" path)
          (alexandria:ends-with-subseq "/cancel" path))
     (cancel-task-handler path))
    ((and (eq method :get) (alexandria:starts-with-subseq "/a2a/task/" path))
     (get-task-handler path))))

(defun start-a2a-server (&key (port 8080))
  "Register A2A routes on the MCP Woo server.
A2A now runs on the same port as MCP (no separate server). PORT is used for
logging the base URL but does not start a new listener — it should match the
port passed to server-start. Returns the base URL string for A2A clients."
  (when *a2a-server*
    (stop-a2a-server))
  (setf *a2a-server* t)
  (setf mcp-lisp/src/transport/mcp-woo::*a2a-handler* #'handle-a2a-request)
  (let ((base-url (format nil "http://localhost:~a" port)))
    (log:info "A2A handler registered on ~a" base-url)
    (format t "~&A2A routes active on ~a~%" base-url)
    (format t "Agent card at: ~a/.well-known/agent.json~%" base-url)
    base-url))

(defun stop-a2a-server ()
  "Unregister A2A handler."
  (when *a2a-server*
    (setf mcp-lisp/src/transport/mcp-woo::*a2a-handler* nil)
    (setf *a2a-server* nil)
    (log:info "A2A handler unregistered")))

;;;; src/a2a/server.lisp
;;;;
;;;; A2A Server - HTTP endpoints for A2A protocol.

(defpackage #:mcp-lisp/src/a2a/server
  (:use #:cl #:log4cl)
  (:import-from #:hunchentoot)
  (:import-from #:flexi-streams)
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
           #:stop-a2a-server))

(in-package #:mcp-lisp/src/a2a/server)

(defvar *a2a-server* nil "Current Hunchentoot acceptor for A2A.")

(defun write-utf8 (string stream)
  "Write STRING to binary STREAM as UTF-8 bytes."
  (write-sequence (flexi-streams:string-to-octets string :external-format :utf-8) stream))

(defun json-response (data)
  "Set up JSON response headers and return encoded data."
  (setf (hunchentoot:content-type*) "application/json")
  (setf (hunchentoot:header-out "Access-Control-Allow-Origin") "*")
  (encode-json data))

(defun agent-card-handler ()
  "Handle GET /.well-known/agent.json - serve agent card."
  (log:info "Agent card requested")
  (if *agent-card*
      (json-response (mcp-lisp/src/a2a/agent-card::agent-card-to-ht *agent-card*))
      (progn
        (setf (hunchentoot:return-code*) 404)
        (json-response (make-ht "error" "No agent card configured")))))

(defun send-message-handler ()
  "Handle POST /a2a/message - receive messages from other agents."
  (setf (hunchentoot:content-type*) "application/json")
  (setf (hunchentoot:header-out "Access-Control-Allow-Origin") "*")

  (handler-case
      (let* ((body (hunchentoot:raw-post-data :force-text t))
             (request (decode-json body))
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

          (json-response (task-to-ht task))))
    (error (e)
      (log:error "A2A message error: ~a" e)
      (setf (hunchentoot:return-code*) 400)
      (json-response (make-ht "error" (princ-to-string e))))))

(defun extract-task-id-from-path (path prefix)
  "Extract task ID from PATH, stripping PREFIX and any trailing segments."
  (let* ((after-prefix (subseq path (length prefix)))
         (slash-pos (position #\/ after-prefix)))
    (if slash-pos
        (subseq after-prefix 0 slash-pos)
        after-prefix)))

(defun get-task-handler ()
  "Handle GET /a2a/task/:id - get task status."
  (let* ((path (hunchentoot:script-name hunchentoot:*request*))
         (task-id (extract-task-id-from-path path "/a2a/task/")))
    (log:debug "Task status requested: ~a" task-id)
    (let ((task (get-task task-id)))
      (if task
          (json-response (task-to-ht task))
          (progn
            (setf (hunchentoot:return-code*) 404)
            (json-response (make-ht "error" "Task not found")))))))

(defun cancel-task-handler ()
  "Handle POST /a2a/task/:id/cancel - cancel a task."
  (let* ((path (hunchentoot:script-name hunchentoot:*request*))
         (task-id (extract-task-id-from-path path "/a2a/task/")))
    (log:debug "Task cancel requested: ~a" task-id)
    (let ((task (get-task task-id)))
      (if task
          (progn
            (cancel-task task)
            (json-response (task-to-ht task)))
          (progn
            (setf (hunchentoot:return-code*) 404)
            (json-response (make-ht "error" "Task not found")))))))

(defun options-handler ()
  "Handle CORS preflight requests."
  (setf (hunchentoot:header-out "Access-Control-Allow-Origin") "*")
  (setf (hunchentoot:header-out "Access-Control-Allow-Methods") "GET, POST, OPTIONS")
  (setf (hunchentoot:header-out "Access-Control-Allow-Headers") "Content-Type")
  "")

(defclass a2a-acceptor (hunchentoot:acceptor)
  ()
  (:documentation "Custom acceptor for A2A server."))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor a2a-acceptor) request)
  (let ((path (hunchentoot:script-name request))
        (method (hunchentoot:request-method request)))
    (log:debug "A2A HTTP ~a ~a" method path)
    (cond
      ((eq method :options)
       (options-handler))
      ((and (eq method :get) (string= path "/.well-known/agent.json"))
       (agent-card-handler))
      ((and (eq method :post) (string= path "/a2a/message"))
       (send-message-handler))
      ((and (eq method :post)
            (alexandria:starts-with-subseq "/a2a/task/" path)
            (alexandria:ends-with-subseq "/cancel" path))
       (cancel-task-handler))
      ((and (eq method :get) (alexandria:starts-with-subseq "/a2a/task/" path))
       (get-task-handler))
      (t
       (setf (hunchentoot:return-code*) 404)
       "Not Found"))))

(defun start-a2a-server (&key (port 8081))
  "Start A2A server on PORT."
  (when *a2a-server*
    (stop-a2a-server))
  (setf *a2a-server* (make-instance 'a2a-acceptor :port port))
  (hunchentoot:start *a2a-server*)
  (log:info "A2A server started on port ~a" port)
  (format t "~&A2A server running on http://localhost:~a~%" port)
  (format t "Agent card at: http://localhost:~a/.well-known/agent.json~%" port)
  *a2a-server*)

(defun stop-a2a-server ()
  "Stop the A2A server."
  (when *a2a-server*
    (hunchentoot:stop *a2a-server*)
    (setf *a2a-server* nil)
    (log:info "A2A server stopped")))

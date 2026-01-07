;;;; src/a2a/client.lisp
;;;;
;;;; A2A Client - connect to and communicate with other agents.

(defpackage #:mcp-lisp/src/a2a/client
  (:use #:cl)
  (:import-from #:dexador)
  (:import-from #:mcp-lisp/src/json
                #:make-ht
                #:encode-json
                #:decode-json)
  (:import-from #:mcp-lisp/src/a2a/messages
                #:message-to-ht)
  (:export #:a2a-client
           #:make-a2a-client
           #:client-agent-url
           #:client-agent-card
           #:fetch-agent-card
           #:send-message
           #:fetch-task-status
           #:request-task-cancel))

(in-package #:mcp-lisp/src/a2a/client)

(defclass a2a-client ()
  ((agent-url :initarg :agent-url
              :reader client-agent-url
              :type string)
   (agent-card :initarg :agent-card
               :initform nil
               :accessor client-agent-card))
  (:documentation "Client for communicating with an A2A agent."))

(defun make-a2a-client (agent-url)
  "Create a client for the agent at AGENT-URL.
AGENT-URL should be the base URL, e.g. http://localhost:8081"
  (make-instance 'a2a-client :agent-url (string-right-trim "/" agent-url)))

(defun fetch-agent-card (client)
  "Fetch and cache the agent card from the remote agent.
Returns the decoded agent card hash-table."
  (let* ((url (format nil "~a/.well-known/agent.json" (client-agent-url client)))
         (response (dex:get url))
         (card (decode-json response)))
    (setf (client-agent-card client) card)
    card))

(defun send-message (client message &key skill-id)
  "Send a message to the remote agent, optionally invoking a specific skill.
MESSAGE can be a hash-table or a message object (will be converted).
Returns the task hash-table from the server."
  (let* ((url (format nil "~a/a2a/message" (client-agent-url client)))
         (payload (make-ht "message" (if (hash-table-p message)
                                         message
                                         (message-to-ht message)))))
    (when skill-id
      (setf (gethash "skillId" payload) skill-id))
    (let ((response (dex:post url
                              :content (encode-json payload)
                              :headers '(("Content-Type" . "application/json")))))
      (decode-json response))))

(defun fetch-task-status (client task-id)
  "Fetch task status from remote agent.
Returns the task hash-table."
  (let* ((url (format nil "~a/a2a/task/~a" (client-agent-url client) task-id))
         (response (dex:get url)))
    (decode-json response)))

(defun request-task-cancel (client task-id)
  "Request task cancellation on remote agent.
Returns the updated task hash-table."
  (let* ((url (format nil "~a/a2a/task/~a/cancel" (client-agent-url client) task-id))
         (response (dex:post url
                             :headers '(("Content-Type" . "application/json")))))
    (decode-json response)))

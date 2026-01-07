;;;; src/a2a/main.lisp
;;;;
;;;; Main package for A2A support in mcp-lisp.

(defpackage #:mcp-lisp/src/a2a/main
  (:use #:cl)
  ;; Agent Card
  (:import-from #:mcp-lisp/src/a2a/agent-card
                #:*agent-card*
                #:agent-card
                #:make-agent-card
                #:define-agent-card
                #:agent-card-to-json
                #:agent-card-id
                #:agent-card-name
                #:agent-card-description
                #:agent-card-service-url
                #:agent-card-skills
                #:add-skill-to-card)
  ;; Skills
  (:import-from #:mcp-lisp/src/a2a/skills
                #:*skill-registry*
                #:define-skill
                #:get-skill
                #:invoke-skill)
  ;; Tasks
  (:import-from #:mcp-lisp/src/a2a/tasks
                #:*task-registry*
                #:task
                #:make-task
                #:task-id
                #:task-status
                #:task-artifacts
                #:task-messages
                #:get-task
                #:create-task
                #:update-task-status
                #:add-task-artifact
                #:add-task-message
                #:cancel-task
                #:task-to-ht)
  ;; Messages
  (:import-from #:mcp-lisp/src/a2a/messages
                #:make-message
                #:make-text-part
                #:make-file-part
                #:make-data-part
                #:message-role
                #:message-parts
                #:message-to-ht)
  ;; Client
  (:import-from #:mcp-lisp/src/a2a/client
                #:a2a-client
                #:make-a2a-client
                #:client-agent-url
                #:client-agent-card
                #:fetch-agent-card
                #:send-message
                #:fetch-task-status
                #:request-task-cancel)
  ;; Server
  (:import-from #:mcp-lisp/src/a2a/server
                #:*a2a-server*
                #:start-a2a-server
                #:stop-a2a-server)
  ;; Export all
  (:export ;; Agent Card
           #:*agent-card*
           #:agent-card
           #:make-agent-card
           #:define-agent-card
           #:agent-card-to-json
           #:agent-card-id
           #:agent-card-name
           #:agent-card-description
           #:agent-card-service-url
           #:agent-card-skills
           #:add-skill-to-card
           ;; Skills
           #:*skill-registry*
           #:define-skill
           #:get-skill
           #:invoke-skill
           ;; Tasks
           #:*task-registry*
           #:task
           #:make-task
           #:task-id
           #:task-status
           #:task-artifacts
           #:task-messages
           #:get-task
           #:create-task
           #:update-task-status
           #:add-task-artifact
           #:add-task-message
           #:cancel-task
           #:task-to-ht
           ;; Messages
           #:make-message
           #:make-text-part
           #:make-file-part
           #:make-data-part
           #:message-role
           #:message-parts
           #:message-to-ht
           ;; Client
           #:a2a-client
           #:make-a2a-client
           #:client-agent-url
           #:client-agent-card
           #:fetch-agent-card
           #:send-message
           #:fetch-task-status
           #:request-task-cancel
           ;; Server
           #:*a2a-server*
           #:start-a2a-server
           #:stop-a2a-server))

(in-package #:mcp-lisp/src/a2a/main)

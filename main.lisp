;;;; main.lisp
;;;;
;;;; Main package for mcp-lisp SDK.

(defpackage #:mcp-lisp/main
  (:use #:cl)
  (:nicknames #:mcp-lisp)
  ;; Re-export from core
  (:import-from #:mcp-lisp/src/core
                #:+protocol-version+
                #:+supported-protocol-versions+
                #:+sdk-version+)
  ;; Re-export from json
  (:import-from #:mcp-lisp/src/json
                #:dict
                #:make-ht
                #:encode-json
                #:decode-json
                #:pp
                #:ht-keys
                #:ht-values)
  ;; Re-export from content
  (:import-from #:mcp-lisp/src/content
                #:text-content
                #:image-content
                #:make-content
                #:content-vector)
  ;; Re-export from conditions
  (:import-from #:mcp-lisp/src/conditions
                #:mcp-error
                #:mcp-error-message
                #:protocol-error
                #:tool-error
                #:tool-error-category
                #:tool-error-retryable-p
                #:transport-error
                #:validation-error)
  ;; Re-export from client
  (:import-from #:mcp-lisp/src/client/client
                #:mcp-client
                #:make-client
                #:make-http-client
                #:client-name
                #:client-version
                #:client-server-info
                #:client-server-capabilities
                #:client-protocol-version
                #:client-connected-p
                #:client-connect
                #:client-disconnect
                #:client-initialize
                #:client-shutdown
                #:client-call
                #:client-notify
                #:client-notification-handler
                #:client-request-handler
                #:with-client)
  (:import-from #:mcp-lisp/src/client/operations
                #:list-tools
                #:call-tool
                #:list-resources
                #:read-resource
                #:list-prompts
                #:get-prompt
                #:ping)
  ;; Re-export from server
  (:import-from #:mcp-lisp/src/server/server
                #:mcp-server
                #:make-server
                #:server-name
                #:server-version
                #:server-start
                #:server-stop
                #:run-server)
  ;; Re-export from tools
  (:import-from #:mcp-lisp/src/primitives/tools/registry
                #:register-tool
                #:unregister-tool
                #:get-tool
                #:get-all-tools
                #:*global-tool-registry*)
  (:import-from #:mcp-lisp/src/primitives/tools/define-tool
                #:define-tool)
  ;; Re-export from prompts
  (:import-from #:mcp-lisp/src/primitives/prompts/registry
                #:register-prompt
                #:unregister-prompt
                #:get-all-prompts
                #:*global-prompt-registry*)
  (:import-from #:mcp-lisp/src/primitives/prompts/define-prompt
                #:define-prompt)
  ;; Re-export from resources
  (:import-from #:mcp-lisp/src/primitives/resources/registry
                #:register-resource
                #:register-resource-template
                #:unregister-resource
                #:unregister-resource-template
                #:get-all-resources
                #:get-all-resource-templates
                #:*global-resource-registry*)
  (:import-from #:mcp-lisp/src/primitives/resources/define-resource
                #:define-resource
                #:define-resource-template)
  ;; Re-export from notifications
  (:import-from #:mcp-lisp/src/server/notifications
                #:notify-tools-list-changed
                #:notify-prompts-list-changed
                #:notify-resources-list-changed
                #:notify-resource-updated)
  ;; Re-export from logging
  (:import-from #:mcp-lisp/src/server/logging
                #:*log-level*
                #:set-log-level)
  ;; Re-export from progress
  (:import-from #:mcp-lisp/src/server/progress
                #:send-progress
                #:with-progress)
  ;; Re-export from mcp-stdio transport
  (:import-from #:mcp-lisp/src/transport/mcp-stdio
                #:setup-file-logging)
  ;; Re-export from sampling
  (:import-from #:mcp-lisp/src/server/sampling
                #:create-message
                #:make-sampling-message
                #:make-model-preferences)
  ;; Re-export from elicitation
  (:import-from #:mcp-lisp/src/server/elicitation
                #:elicit-form
                #:elicit-url)
  ;; Re-export from A2A
  (:import-from #:mcp-lisp/src/a2a/main
                ;; Agent Card
                #:*agent-card*
                #:define-agent-card
                #:agent-card-to-json
                ;; Skills
                #:define-skill
                #:invoke-skill
                ;; Tasks
                #:create-task
                #:task-id
                #:task-status
                #:task-to-ht
                ;; Messages
                #:make-message
                #:make-text-part
                #:make-file-part
                #:make-data-part
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
                #:start-a2a-server
                #:stop-a2a-server)
  ;; Agent
  (:import-from #:mcp-lisp/src/agent/agent
                #:*provider*
                #:*api-key*
                #:*model*
                #:*max-tokens*
                #:*verbose*
                #:*last-api-usage*
                #:*session-tokens*
                #:reset-session-tokens
                #:run-agent
                #:chat)
  ;; Agent tools (loading this registers the tools)
  (:import-from #:mcp-lisp/src/agent/tools
                #:*search-api-key*)
  ;; Spec DSL
  (:import-from #:mcp-lisp/src/spec/spec
                #:*entities*
                #:*rules*
                #:*invariants*
                #:defentity
                #:defrule
                #:definvariant
                #:list-entities
                #:describe-entity
                #:entity-fields
                #:entity-relations
                #:list-rules
                #:describe-rule
                #:list-invariants
                #:describe-invariant
                #:clear-specs
                #:validate-specs
                #:form-to-ast
                #:ast-to-form
                #:specs-to-json
                #:json-to-specs
                #:spec-json-schema)
  ;; Spec PBT
  (:import-from #:mcp-lisp/src/spec/pbt
                #:generate-value
                #:generate-instance
                #:default-generate-instance
                #:defgenerator
                #:ensure-entity-accessors
                #:check-invariants
                #:run-pbt
                #:extract-generation-constraints)
  ;; Export everything
  (:export ;; Core
   #:+protocol-version+
   #:+supported-protocol-versions+
   #:+sdk-version+
   ;; JSON
   #:dict
   #:make-ht
   #:encode-json
   #:decode-json
   #:pp
   #:ht-keys
   #:ht-values
   ;; Content
   #:text-content
   #:image-content
   #:make-content
   #:content-vector
   ;; Conditions
   #:mcp-error
   #:mcp-error-message
   #:protocol-error
   #:tool-error
   #:tool-error-category
   #:tool-error-retryable-p
   #:transport-error
   #:validation-error
   ;; Client
   #:mcp-client
   #:make-client
   #:make-http-client
   #:client-name
   #:client-version
   #:client-server-info
   #:client-server-capabilities
   #:client-protocol-version
   #:client-connected-p
   #:client-connect
   #:client-disconnect
   #:client-initialize
   #:client-shutdown
   #:client-call
   #:client-notify
   #:client-notification-handler
   #:client-request-handler
   #:with-client
   ;; Client operations
   #:list-tools
   #:call-tool
   #:list-resources
   #:read-resource
   #:list-prompts
   #:get-prompt
   #:ping
   ;; Server
   #:mcp-server
   #:make-server
   #:server-name
   #:server-version
   #:server-start
   #:server-stop
   #:run-server
   ;; Tools
   #:register-tool
   #:unregister-tool
   #:get-tool
   #:get-all-tools
   #:*global-tool-registry*
   #:define-tool
   ;; Prompts
   #:register-prompt
   #:unregister-prompt
   #:get-all-prompts
   #:*global-prompt-registry*
   #:define-prompt
   ;; Resources
   #:register-resource
   #:register-resource-template
   #:unregister-resource
   #:unregister-resource-template
   #:get-all-resources
   #:get-all-resource-templates
   #:*global-resource-registry*
   #:define-resource
   #:define-resource-template
   ;; Notifications
   #:notify-tools-list-changed
   #:notify-prompts-list-changed
   #:notify-resources-list-changed
   #:notify-resource-updated
   ;; Logging
   #:*log-level*
   #:set-log-level
   ;; Progress
   #:send-progress
   #:with-progress
   ;; Sampling
   #:create-message
   #:make-sampling-message
   #:make-model-preferences
   ;; Elicitation
   #:elicit-form
   #:elicit-url
   ;; Transport utilities
   #:setup-file-logging
   ;; A2A - Agent Card
   #:*agent-card*
   #:define-agent-card
   #:agent-card-to-json
   ;; A2A - Skills
   #:define-skill
   #:invoke-skill
   ;; A2A - Tasks
   #:create-task
   #:task-id
   #:task-status
   #:task-to-ht
   ;; A2A - Messages
   #:make-message
   #:make-text-part
   #:make-file-part
   #:make-data-part
   ;; A2A - Client
   #:a2a-client
   #:make-a2a-client
   #:client-agent-url
   #:client-agent-card
   #:fetch-agent-card
   #:send-message
   #:fetch-task-status
   #:request-task-cancel
   ;; A2A - Server
   #:start-a2a-server
   #:stop-a2a-server
   ;; Agent
   #:*provider*
   #:*api-key*
   #:*model*
   #:*max-tokens*
   #:*verbose*
   #:*last-api-usage*
   #:*session-tokens*
   #:reset-session-tokens
   #:*search-api-key*
   #:run-agent
   #:chat
   ;; Spec DSL
   #:*entities*
   #:*rules*
   #:*invariants*
   #:defentity
   #:defrule
   #:definvariant
   #:list-entities
   #:describe-entity
   #:entity-fields
   #:entity-relations
   #:list-rules
   #:describe-rule
   #:list-invariants
   #:describe-invariant
   #:clear-specs
   #:validate-specs
   #:form-to-ast
   #:ast-to-form
   #:specs-to-json
   #:json-to-specs
   #:spec-json-schema
   ;; Spec PBT
   #:generate-value
   #:generate-instance
   #:default-generate-instance
   #:defgenerator
   #:ensure-entity-accessors
   #:check-invariants
   #:run-pbt
   #:extract-generation-constraints))

(in-package #:mcp-lisp/main)

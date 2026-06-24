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
                #:*log-levels*
                #:log-level-value
                #:send-log)
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
  ;; Re-export from tool-context (handler-facing progress/sampling/elicitation)
  (:import-from #:mcp-lisp/src/server/tool-context
                #:*tool-context*
                #:tool-streaming-available-p
                #:tool-report-progress
                #:tool-sample
                #:tool-elicit-form
                #:tool-elicit-url
                #:tool-log)
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
                #:*variants*
                #:*config*
                #:*current-config*
                #:defentity
                #:defmixin
                #:defcompound
                #:defrule
                #:definvariant
                #:defvariant
                #:defconfig
                #:config
                #:list-entities
                #:describe-entity
                #:entity-fields
                #:entity-relations
                #:list-rules
                #:describe-rule
                #:list-invariants
                #:describe-invariant
                #:list-variants
                #:describe-variant
                #:entity-variants
                #:describe-config
                #:config-fields
                #:*scenarios*
                #:*scenario-generators*
                #:list-mixins
                #:list-compounds
                #:defscenario
                #:defhelper
                #:defvalueset
                #:defreq
                #:in-set
                #:list-scenarios
                #:describe-scenario
                #:list-valuesets
                #:list-requirements
                #:clear-specs
                #:validate-specs
                #:suggest-invariants
                #:compliance-matrix
                #:form-to-ast
                #:ast-to-form
                #:specs-to-json
                #:json-to-specs
                #:spec-json-schema
                #:specs-to-lisp
                #:specs-to-data
                #:data-to-specs
                #:write-specs
                #:read-specs
                #:list-dsl-forms
                #:describe-dsl
                #:spec-reference)
  ;; Spec transitions
  (:import-from #:mcp-lisp/src/spec/transitions
                #:detect-state-fields
                #:extract-transitions
                #:unreachable-states
                #:terminal-states
                #:dead-end-states
                #:analyze-state-machine
                #:validate-transitions)
  ;; Spec PBT
  (:import-from #:mcp-lisp/src/spec/pbt
                #:generate-value
                #:generate-instance
                #:default-generate-instance
                #:defgenerator
                #:override-val
                #:override-present-p
                #:ensure-entity-accessors
                #:ensure-variant-accessors
                #:generate-config
                #:config-invariants
                #:check-config-invariants
                #:check-invariants
                #:check-scenario-invariants
                #:scenario-invariants-for
                #:generate-scenario
                #:default-generate-scenario
                #:defscenario-generator
                #:defscenario-negative-generator
                #:run-pbt
                #:check-scenario
                #:extract-generation-constraints
                #:apply-rule
                #:applicable-rules
                #:random-walk
                #:random-walk-scenario
                #:all-pairs-check
                #:consecutive-pairs-check
                #:distribute-values
                #:partition-into
                #:haversine-distance-nm
                #:initial-bearing-deg
                #:heading-difference-deg
                #:point-in-polygon-p
                #:intervals-overlap-p
                #:interval-contains-p
                #:interval-before-p
                #:elapsed-since
                #:duration-at-least-p
                #:within-retention-period-p)
  ;; Spec analysis
  (:import-from #:mcp-lisp/src/spec/analysis
                #:invariant-coverage
                #:invariant-coverage-summary
                #:field-index
                #:generation-feasibility
                #:simulate-trace
                #:scenario-feasibility
                #:diff-specs)
  ;; Spec codegen
  (:import-from #:mcp-lisp/src/spec/codegen
                #:specs-to-sql
                #:specs-to-sql-seed)
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
   #:*log-levels*
   #:log-level-value
   #:send-log
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
   ;; Tool execution context (handler-facing helpers)
   #:*tool-context*
   #:tool-streaming-available-p
   #:tool-report-progress
   #:tool-sample
   #:tool-elicit-form
   #:tool-elicit-url
   #:tool-log
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
   #:*variants*
   #:*config*
   #:*current-config*
   #:defentity
   #:defmixin
   #:defcompound
   #:defrule
   #:definvariant
   #:defvariant
   #:defconfig
   #:config
   #:list-entities
   #:describe-entity
   #:entity-fields
   #:entity-relations
   #:list-rules
   #:describe-rule
   #:list-invariants
   #:describe-invariant
   #:list-variants
   #:describe-variant
   #:entity-variants
   #:describe-config
   #:config-fields
   #:*scenarios*
   #:*scenario-generators*
   #:list-mixins
   #:list-compounds
   #:defscenario
   #:defhelper
   #:defvalueset
   #:defreq
   #:in-set
   #:list-scenarios
   #:describe-scenario
   #:list-valuesets
   #:list-requirements
   #:clear-specs
   #:validate-specs
   #:compliance-matrix
   #:form-to-ast
   #:ast-to-form
   #:specs-to-json
   #:json-to-specs
   #:spec-json-schema
   #:specs-to-lisp
   #:specs-to-data
   #:data-to-specs
   #:write-specs
   #:read-specs
   ;; Spec transitions
   #:detect-state-fields
   #:extract-transitions
   #:unreachable-states
   #:terminal-states
   #:dead-end-states
   #:analyze-state-machine
   #:validate-transitions
   ;; Spec PBT
   #:generate-value
   #:generate-instance
   #:default-generate-instance
   #:defgenerator
   #:override-val
   #:override-present-p
   #:ensure-entity-accessors
   #:ensure-variant-accessors
   #:generate-config
   #:config-invariants
   #:check-config-invariants
   #:check-invariants
   #:check-scenario-invariants
   #:scenario-invariants-for
   #:generate-scenario
   #:default-generate-scenario
   #:defscenario-generator
   #:defscenario-negative-generator
   #:run-pbt
   #:check-scenario
   #:extract-generation-constraints
   #:apply-rule
   #:applicable-rules
   #:random-walk
   #:random-walk-scenario
   #:all-pairs-check
   #:consecutive-pairs-check
   #:distribute-values
   #:partition-into
   #:haversine-distance-nm
   #:initial-bearing-deg
   #:heading-difference-deg
   #:point-in-polygon-p
   #:intervals-overlap-p
   #:interval-contains-p
   #:interval-before-p
   #:elapsed-since
   #:duration-at-least-p
   #:within-retention-period-p
   ;; Spec analysis
   #:invariant-coverage
   #:invariant-coverage-summary
   #:field-index
   #:generation-feasibility
   #:simulate-trace
   #:scenario-feasibility
   #:diff-specs
   #:suggest-invariants
   ;; Spec codegen
   #:specs-to-sql
   #:specs-to-sql-seed
   ;; Spec reflection
   #:list-dsl-forms
   #:describe-dsl
   #:spec-reference))

(in-package #:mcp-lisp/main)

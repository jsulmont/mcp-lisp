;;;; src/spec/spec.lisp
;;;;
;;;; Behavioral specification DSL — entity definitions, rules, and invariants
;;;; stored as structured metadata. Inspired by JUXT Allium but delivered as
;;;; an in-process CL service rather than a file format.

(defpackage #:mcp-lisp/src/spec/spec
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:dict
                #:encode-json
                #:decode-json)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*entities*
                #:*rules*
                #:*invariants*
                #:*generators*
                #:*generator-sources*
                #:*variants*
                #:*config*
                #:*current-config*
                #:*scenarios*
                #:*scenario-generators*
                #:*scenario-generator-sources*
                #:*scenario-negative-generators*
                #:*scenario-negative-generator-sources*
                #:*compiled-fn-cache*
                #:*helpers*
                #:*helper-sources*
                #:*valuesets*
                #:*requirements*
                #:+known-field-keys+
                #:+relation-types+
                #:clear-specs)
  (:import-from #:mcp-lisp/src/spec/dsl
                #:defentity
                #:defrule
                #:definvariant
                #:defvariant
                #:defconfig
                #:defscenario
                #:defhelper
                #:defvalueset
                #:defreq
                #:register-entity-accessors
                #:in-set
                #:list-valuesets
                #:list-requirements)
  (:import-from #:mcp-lisp/src/spec/validation
                #:validate-specs
                #:suggest-invariants)
  (:import-from #:mcp-lisp/src/spec/serialization
                #:form-to-ast
                #:ast-to-form
                #:specs-to-json
                #:json-to-specs
                #:spec-json-schema
                #:specs-to-lisp
                #:specs-to-data
                #:data-to-specs
                #:write-specs
                #:read-specs)
  (:import-from #:mcp-lisp/src/spec/introspection
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
                #:config
                #:list-scenarios
                #:describe-scenario
                #:compliance-matrix
                #:entity-accessor-p
                #:config-accessor-p
                #:variant-accessor-p
                #:decompose-accessor)
  (:export ;; Registries
           #:*entities*
           #:*rules*
           #:*invariants*
           #:*generators*
           #:*generator-sources*
           #:*variants*
           #:*config*
           #:*current-config*
           ;; Macros
           #:defentity
           #:defrule
           #:definvariant
           #:defvariant
           #:defconfig
           ;; Introspection
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
           #:config
           ;; Scenarios
           #:*scenarios*
           #:*scenario-generators*
           #:*scenario-generator-sources*
           #:*scenario-negative-generators*
           #:*scenario-negative-generator-sources*
           #:*compiled-fn-cache*
           #:*helpers*
           #:*helper-sources*
           #:*valuesets*
           #:*requirements*
           #:defscenario
           #:defhelper
           #:defvalueset
           #:defreq
           #:in-set
           #:list-scenarios
           #:describe-scenario
           #:list-valuesets
           #:list-requirements
           ;; Utilities
           #:register-entity-accessors
           #:clear-specs
           #:entity-accessor-p
           #:config-accessor-p
           #:variant-accessor-p
           #:decompose-accessor
           #:validate-specs
           #:suggest-invariants
           #:compliance-matrix
           ;; AST
           #:form-to-ast
           #:ast-to-form
           ;; JSON
           #:specs-to-json
           #:json-to-specs
           #:spec-json-schema
           ;; Lisp serialization
           #:specs-to-lisp
           ;; S-expression data serialization
           #:specs-to-data
           #:data-to-specs
           #:write-specs
           #:read-specs))

(in-package #:mcp-lisp/src/spec/spec)


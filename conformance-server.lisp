;;;; conformance-server.lisp
;;;; MCP conformance test server — implements fixtures expected by
;;;; npx @modelcontextprotocol/conformance server --url http://localhost:8080/mcp

(ql:quickload :mcp-lisp :silent t)

(defpackage #:conformance
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json #:make-ht #:encode-json)
  (:import-from #:mcp-lisp/src/content #:text-content)
  (:import-from #:mcp-lisp/src/primitives/tools/registry #:register-tool)
  (:import-from #:mcp-lisp/src/primitives/tools/schema #:make-input-schema)
  (:import-from #:mcp-lisp/src/primitives/prompts/registry
                #:register-prompt #:*global-prompt-registry*)
  (:import-from #:mcp-lisp/src/primitives/resources/registry
                #:register-resource #:register-resource-template)
  (:import-from #:mcp-lisp/src/transport/mcp-woo
                #:*stream-notify-fn* #:*stream-call-fn*)
  (:import-from #:mcp-lisp/src/server/dispatcher #:*request-meta*))

(in-package #:conformance)

;;;; ========= Helpers =========

(defvar *test-png*
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==")

(defvar *test-wav*
  "UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA=")

(defun empty-schema ()
  (make-input-schema (make-hash-table :test #'equal) nil))

(defun tool-props (&rest name-schema-pairs)
  "Build a properties hash-table from (name schema) pairs."
  (let ((ht (make-hash-table :test #'equal)))
    (loop for (name schema) on name-schema-pairs by #'cddr
          do (setf (gethash name ht) schema))
    ht))

(defun simple-tool (name description handler-fn)
  "Register a no-args tool with a nullary handler."
  (register-tool name description (empty-schema)
                 (lambda (server session args)
                   (declare (ignore server session args))
                   (funcall handler-fn))))

(defun stream-notify (method params)
  "Send a notification via the active SSE stream (noop if not streaming)."
  (when *stream-notify-fn*
    (funcall *stream-notify-fn* method params)))

(defun stream-call (method params)
  "Send a request via SSE and wait for response. Errors if not streaming."
  (unless *stream-call-fn*
    (error "Not in streaming context"))
  (funcall *stream-call-fn* method params))

(defun do-elicitation (message schema)
  "Request elicitation from client, return result. Errors if not streaming."
  (stream-call "elicitation/create"
               (make-ht "message" message "requestedSchema" schema)))

(defun format-elicitation-result (result)
  "Format an elicitation result into a text content vector."
  (vector (text-content (format nil "Elicitation completed: action=~a, content=~a"
                                (gethash "action" result)
                                (encode-json (or (gethash "content" result) (make-ht)))))))

(defun elicitation-tool (name description schema-fn)
  "Register a tool that performs elicitation with the given schema."
  (simple-tool name description
               (lambda ()
                 (if *stream-call-fn*
                     (format-elicitation-result
                      (do-elicitation (format nil "~a" description) (funcall schema-fn)))
                     (vector (text-content "Elicitation completed: action=accept, content={}"))))))

(defun enum-schema (values)
  "Simple string enum."
  (make-ht "type" "string" "enum" (coerce values 'vector)))

(defun titled-enum-schema (value-title-pairs)
  "String enum with titled options via oneOf."
  (make-ht "type" "string"
           "oneOf" (coerce (loop for (val title) on value-title-pairs by #'cddr
                                 collect (make-ht "const" val "title" title))
                           'vector)))

(defun legacy-enum-schema (values names)
  "Deprecated enumNames-style enum."
  (make-ht "type" "string"
           "enum" (coerce values 'vector)
           "enumNames" (coerce names 'vector)))

(defun multi-enum-schema (values)
  "Array of string enum (multi-select)."
  (make-ht "type" "array" "items" (make-ht "type" "string"
                                           "enum" (coerce values 'vector))))

(defun titled-multi-enum-schema (value-title-pairs)
  "Array with anyOf titled options (multi-select)."
  (make-ht "type" "array"
           "items" (make-ht "anyOf" (coerce (loop for (val title) on value-title-pairs by #'cddr
                                                  collect (make-ht "const" val "title" title))
                                            'vector))))

(defun user-message (content)
  "Create a prompt message hash-table with role=user."
  (make-ht "role" "user" "content" content))

(defun text-message (text)
  (user-message (make-ht "type" "text" "text" text)))

;;;; ========= TOOLS =========

(simple-tool "test_simple_text" "Returns simple text for testing"
             (lambda () (vector (text-content "This is a simple text response for testing."))))

(simple-tool "test_image_content" "Returns image content for testing"
             (lambda () (vector (make-ht "type" "image" "data" *test-png* "mimeType" "image/png"))))

(simple-tool "test_audio_content" "Returns audio content for testing"
             (lambda () (vector (make-ht "type" "audio" "data" *test-wav* "mimeType" "audio/wav"))))

(simple-tool "test_embedded_resource" "Returns embedded resource content"
             (lambda () (vector (make-ht "type" "resource"
                                         "resource" (make-ht "uri" "test://embedded-resource"
                                                             "mimeType" "text/plain"
                                                             "text" "This is an embedded resource content.")))))

(simple-tool "test_multiple_content_types" "Returns multiple content types"
             (lambda ()
               (vector (text-content "Multiple content types test:")
                       (make-ht "type" "image" "data" *test-png* "mimeType" "image/png")
                       (make-ht "type" "resource"
                                "resource" (make-ht "uri" "test://mixed-content-resource"
                                                    "mimeType" "application/json"
                                                    "text" (encode-json (make-ht "test" "data" "value" 123)))))))

(simple-tool "test_error_handling" "Always returns an error"
             (lambda ()
               (error 'mcp-lisp/src/conditions:tool-error
                      :message "This tool intentionally returns an error for testing")))

(simple-tool "test_tool_with_logging" "Sends log messages during execution"
             (lambda ()
               (dolist (msg '("Tool execution started" "Tool processing data" "Tool execution completed"))
                 (stream-notify "notifications/message" (make-ht "level" "info" "data" msg))
                 (sleep 0.05))
               (vector (text-content "Tool execution with logging completed"))))

(simple-tool "test_tool_with_progress" "Reports progress during execution"
             (lambda ()
               (let ((token (let ((meta *request-meta*))
                              (and meta (gethash "progressToken" meta)))))
                 (when token
                   (dolist (n '(0 50 100))
                     (stream-notify "notifications/progress"
                                    (make-ht "progressToken" token "progress" n "total" 100))
                     (sleep 0.05))))
               (vector (text-content "Tool execution with progress completed"))))

(let ((props (tool-props "prompt" (make-ht "type" "string" "description" "The prompt to send to the LLM"))))
  (register-tool "test_sampling" "Requests LLM sampling from client"
                 (make-input-schema props '("prompt"))
                 (lambda (server session args)
                   (declare (ignore server session))
                   (let ((prompt (gethash "prompt" args)))
                     (if *stream-call-fn*
                         (let* ((result (stream-call "sampling/createMessage"
                                                     (make-ht "messages" (vector (make-ht "role" "user"
                                                                                          "content" (make-ht "type" "text" "text" prompt)))
                                                              "maxTokens" 100)))
                                (content (gethash "content" result))
                                (text (if (hash-table-p content) (gethash "text" content) (encode-json content))))
                           (vector (text-content (format nil "LLM response: ~a" text))))
                         (vector (text-content (format nil "LLM response: (no streaming) prompt=~a" prompt))))))))

(let ((props (tool-props "message" (make-ht "type" "string" "description" "The message to show the user"))))
  (register-tool "test_elicitation" "Requests user input from client"
                 (make-input-schema props '("message"))
                 (lambda (server session args)
                   (declare (ignore server session))
                   (let ((message (gethash "message" args)))
                     (if *stream-call-fn*
                         (let ((result (do-elicitation
                                        message
                                        (make-ht "type" "object"
                                                 "properties" (tool-props
                                                               "username" (make-ht "type" "string" "description" "User's response")
                                                               "email" (make-ht "type" "string" "description" "User's email address"))
                                                 "required" (vector "username" "email")))))
                           (vector (text-content (format nil "User response: action=~a, content=~a"
                                                        (gethash "action" result)
                                                        (encode-json (gethash "content" result))))))
                         (vector (text-content (format nil "User response: (no streaming) message=~a" message))))))))

(elicitation-tool "test_elicitation_sep1034_defaults"
                  "Please provide your information"
                  (lambda ()
                    (make-ht "type" "object"
                             "properties" (tool-props
                                           "name" (make-ht "type" "string" "default" "John Doe")
                                           "age" (make-ht "type" "integer" "default" 30)
                                           "score" (make-ht "type" "number" "default" 95.5)
                                           "status" (make-ht "type" "string"
                                                             "enum" (vector "active" "inactive" "pending")
                                                             "default" "active")
                                           "verified" (make-ht "type" "boolean" "default" t)))))

(elicitation-tool "test_elicitation_sep1330_enums"
                  "Please select options"
                  (lambda ()
                    (make-ht "type" "object"
                             "properties"
                             (tool-props
                              "untitledSingle" (enum-schema '("option1" "option2" "option3"))
                              "titledSingle"   (titled-enum-schema '("value1" "First Option"
                                                                     "value2" "Second Option"
                                                                     "value3" "Third Option"))
                              "legacyEnum"     (legacy-enum-schema '("opt1" "opt2" "opt3")
                                                                   '("Option One" "Option Two" "Option Three"))
                              "untitledMulti"  (multi-enum-schema '("option1" "option2" "option3"))
                              "titledMulti"    (titled-multi-enum-schema '("value1" "First Choice"
                                                                          "value2" "Second Choice"
                                                                          "value3" "Third Choice"))))))

;;; json_schema_2020_12_tool
(let ((schema (make-hash-table :test #'equal)))
  (setf (gethash "$schema" schema) "https://json-schema.org/draft/2020-12/schema"
        (gethash "type" schema) "object"
        (gethash "$defs" schema) (make-ht "address"
                                          (make-ht "type" "object"
                                                   "properties" (tool-props "street" (make-ht "type" "string")
                                                                            "city" (make-ht "type" "string"))))
        (gethash "properties" schema) (tool-props "name" (make-ht "type" "string")
                                                  "address" (make-ht "$ref" "#/$defs/address"))
        (gethash "additionalProperties" schema) nil)
  (register-tool "json_schema_2020_12_tool" "Tool with JSON Schema 2020-12 features" schema
                 (lambda (server session args) (declare (ignore server session args))
                   (vector (text-content "OK")))))

(simple-tool "test_reconnection" "Test tool for SSE reconnection"
             (lambda () (vector (text-content "Reconnection test completed"))))

;;;; ========= RESOURCES =========

(register-resource "test://static-text" "Static Text Resource"
                   "A static text resource for testing"
                   (lambda (server session) (declare (ignore server session))
                     "This is the content of the static text resource.")
                   :mime-type "text/plain")

(register-resource "test://static-binary" "Static Binary Resource"
                   "A static binary resource for testing"
                   (lambda (server session) (declare (ignore server session))
                     (make-ht "blob" *test-png*))
                   :mime-type "image/png")

(register-resource-template "test://template/{id}/data" "Template Resource"
                            "A template resource for testing"
                            (lambda (server session params)
                              (declare (ignore server session))
                              (let ((id (cdr (assoc "id" params :test #'string=))))
                                (encode-json (make-ht "id" id "templateTest" t
                                                      "data" (format nil "Data for ID: ~a" id)))))
                            :mime-type "application/json")

;;;; ========= PROMPTS =========

(register-prompt "test_simple_prompt" "A simple test prompt" nil
                 (lambda (server session args) (declare (ignore server session args))
                   (list (text-message "This is a simple prompt for testing.")))
                 *global-prompt-registry*)

(let ((arg-desc (list (make-ht "name" "arg1" "description" "First test argument" "required" t)
                      (make-ht "name" "arg2" "description" "Second test argument" "required" t))))
  (register-prompt "test_prompt_with_arguments" "A prompt with arguments" arg-desc
                   (lambda (server session args) (declare (ignore server session))
                     (list (text-message (format nil "Prompt with arguments: arg1='~a', arg2='~a'"
                                                 (gethash "arg1" args) (gethash "arg2" args)))))
                   *global-prompt-registry*))

(let ((arg-desc (list (make-ht "name" "resourceUri" "description" "URI of the resource to embed" "required" t))))
  (register-prompt "test_prompt_with_embedded_resource" "A prompt with embedded resource" arg-desc
                   (lambda (server session args) (declare (ignore server session))
                     (list (user-message (make-ht "type" "resource"
                                                  "resource" (make-ht "uri" (gethash "resourceUri" args)
                                                                      "mimeType" "text/plain"
                                                                      "text" "Embedded resource content for testing.")))
                           (text-message "Please process the embedded resource above.")))
                   *global-prompt-registry*))

(register-prompt "test_prompt_with_image" "A prompt with image content" nil
                 (lambda (server session args) (declare (ignore server session args))
                   (list (user-message (make-ht "type" "image" "data" *test-png* "mimeType" "image/png"))
                         (text-message "Please analyze the image above.")))
                 *global-prompt-registry*)

;;;; ========= START SERVER =========

;; Enable structured access logging to stdout
(setf mcp-lisp/src/transport/mcp-woo:*access-log-stream* *standard-output*)

(format t "~%Starting MCP conformance server on port 8080...~%")
(format t "Press Ctrl-C to stop.~%")
(let ((server (mcp-lisp:make-server :name "mcp-lisp-conformance" :version "0.1.0")))
  (mcp-lisp:server-start server :transport :sse :port 8080)
  (handler-case (loop (sleep 3600))
    (#+sbcl sb-sys:interactive-interrupt
     #-sbcl condition ()
      (format t "~%Shutting down...~%")
      (mcp-lisp:server-stop server)
      (sb-ext:exit :code 0))))

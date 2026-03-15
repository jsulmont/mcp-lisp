;;;; src/primitives/tools/registry.lisp
;;;;
;;;; Tool registry for storing and retrieving tool definitions.

(defpackage #:mcp-lisp/src/primitives/tools/registry
  (:use #:cl)
  (:export #:tool-entry
           #:tool-entry-name
           #:tool-entry-title
           #:tool-entry-description
           #:tool-entry-input-schema
           #:tool-entry-output-schema
           #:tool-entry-handler
           #:tool-entry-annotations
           #:make-tool-entry
           #:*global-tool-registry*
           #:register-tool
           #:unregister-tool
           #:get-tool
           #:get-tool-handler
           #:get-all-tools
           #:get-all-tool-descriptors
           #:clear-tools))

(in-package #:mcp-lisp/src/primitives/tools/registry)

(defstruct tool-entry
  "A registered tool entry."
  (name "" :type string)
  (title nil :type (or null string))
  (description "" :type string)
  (input-schema nil :type (or null hash-table))
  (output-schema nil :type (or null hash-table))
  (handler nil :type (or null function))
  (annotations nil :type (or null hash-table)))

(defvar *global-tool-registry* (make-hash-table :test #'equal)
  "Global registry of tools, keyed by tool name.")

(defun register-tool (name description input-schema handler &key title output-schema annotations (registry *global-tool-registry*))
  "Register a tool in the registry."
  (setf (gethash name registry)
        (make-tool-entry :name name
                         :title title
                         :description description
                         :input-schema input-schema
                         :output-schema output-schema
                         :handler handler
                         :annotations annotations))
  name)

(defun unregister-tool (name &optional (registry *global-tool-registry*))
  "Remove a tool from the registry."
  (remhash name registry))

(defun get-tool (name &optional (registry *global-tool-registry*))
  "Get a tool entry by NAME."
  (gethash name registry))

(defun get-tool-handler (name &optional (registry *global-tool-registry*))
  "Get the handler function for tool NAME."
  (let ((entry (get-tool name registry)))
    (and entry (tool-entry-handler entry))))

(defun get-all-tools (&optional (registry *global-tool-registry*))
  "Get all tool entries as a list."
  (loop for entry being the hash-values of registry
        collect entry))

(defun tool-entry-to-descriptor (entry)
  "Convert a tool-entry to an MCP tool descriptor hash-table."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "name" ht) (tool-entry-name entry))
    (when (tool-entry-title entry)
      (setf (gethash "title" ht) (tool-entry-title entry)))
    (setf (gethash "description" ht) (tool-entry-description entry))
    (when (tool-entry-input-schema entry)
      (setf (gethash "inputSchema" ht) (tool-entry-input-schema entry)))
    (when (tool-entry-output-schema entry)
      (setf (gethash "outputSchema" ht) (tool-entry-output-schema entry)))
    (when (tool-entry-annotations entry)
      (setf (gethash "annotations" ht) (tool-entry-annotations entry)))
    ht))

(defun get-all-tool-descriptors (&optional (registry *global-tool-registry*))
  "Get all tool descriptors as a vector for tools/list response."
  (coerce (mapcar #'tool-entry-to-descriptor (get-all-tools registry))
          'vector))

(defun clear-tools (&optional (registry *global-tool-registry*))
  "Clear all tools from the registry."
  (clrhash registry))

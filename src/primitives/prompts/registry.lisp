;;;; src/primitives/prompts/registry.lisp
;;;;
;;;; Prompt registry for storing and retrieving prompt definitions.

(defpackage #:mcp-lisp/src/primitives/prompts/registry
  (:use #:cl)
  (:export #:prompt-entry
           #:prompt-entry-name
           #:prompt-entry-description
           #:prompt-entry-arguments
           #:prompt-entry-handler
           #:make-prompt-entry
           #:*global-prompt-registry*
           #:register-prompt
           #:unregister-prompt
           #:get-prompt
           #:get-prompt-handler
           #:get-all-prompts
           #:get-all-prompt-descriptors
           #:clear-prompts))

(in-package #:mcp-lisp/src/primitives/prompts/registry)

(defstruct prompt-entry
  "A registered prompt entry."
  (name "" :type string)
  (description "" :type string)
  (arguments nil :type list)
  (handler nil :type (or null function)))

(defvar *global-prompt-registry* (make-hash-table :test #'equal)
  "Global registry of prompts, keyed by prompt name.")

(defun register-prompt (name description arguments handler &optional (registry *global-prompt-registry*))
  "Register a prompt in the registry.
ARGUMENTS is a list of argument descriptors (hash-tables with name, description, required)."
  (setf (gethash name registry)
        (make-prompt-entry :name name
                           :description description
                           :arguments arguments
                           :handler handler))
  name)

(defun unregister-prompt (name &optional (registry *global-prompt-registry*))
  "Remove a prompt from the registry."
  (remhash name registry))

(defun get-prompt (name &optional (registry *global-prompt-registry*))
  "Get a prompt entry by NAME."
  (gethash name registry))

(defun get-prompt-handler (name &optional (registry *global-prompt-registry*))
  "Get the handler function for prompt NAME."
  (let ((entry (get-prompt name registry)))
    (and entry (prompt-entry-handler entry))))

(defun get-all-prompts (&optional (registry *global-prompt-registry*))
  "Get all prompt entries as a list."
  (loop for entry being the hash-values of registry
        collect entry))

(defun prompt-entry-to-descriptor (entry)
  "Convert a prompt-entry to an MCP prompt descriptor hash-table."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "name" ht) (prompt-entry-name entry))
    (setf (gethash "description" ht) (prompt-entry-description entry))
    (when (prompt-entry-arguments entry)
      (setf (gethash "arguments" ht)
            (coerce (prompt-entry-arguments entry) 'vector)))
    ht))

(defun get-all-prompt-descriptors (&optional (registry *global-prompt-registry*))
  "Get all prompt descriptors as a vector for prompts/list response."
  (map 'vector #'prompt-entry-to-descriptor (get-all-prompts registry)))

(defun clear-prompts (&optional (registry *global-prompt-registry*))
  "Clear all prompts from the registry."
  (clrhash registry))

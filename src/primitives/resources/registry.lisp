;;;; src/primitives/resources/registry.lisp
;;;;
;;;; Resource registry for storing and retrieving resource definitions.

(defpackage #:mcp-lisp/src/primitives/resources/registry
  (:use #:cl)
  (:export #:make-resource-registry
           #:resource-entry
           #:resource-entry-uri
           #:resource-entry-name
           #:resource-entry-description
           #:resource-entry-mime-type
           #:resource-entry-handler
           #:make-resource-entry
           #:resource-template-entry
           #:resource-template-entry-uri-template
           #:resource-template-entry-name
           #:resource-template-entry-description
           #:resource-template-entry-mime-type
           #:resource-template-entry-handler
           #:make-resource-template-entry
           #:*global-resource-registry*
           #:register-resource
           #:register-resource-template
           #:unregister-resource
           #:unregister-resource-template
           #:get-resource
           #:get-resource-handler
           #:find-matching-template
           #:get-all-resources
           #:get-all-resource-templates
           #:get-all-resource-descriptors
           #:get-all-template-descriptors
           #:clear-resources))

(in-package #:mcp-lisp/src/primitives/resources/registry)

;;; Static resources (fixed URIs)

(defstruct resource-entry
  "A registered static resource entry."
  (uri "" :type string)
  (name "" :type string)
  (description "" :type string)
  (mime-type nil :type (or null string))
  (handler nil :type (or null function)))

;;; Resource templates (URI patterns)

(defstruct resource-template-entry
  "A registered resource template entry."
  (uri-template "" :type string)
  (name "" :type string)
  (description "" :type string)
  (mime-type nil :type (or null string))
  (handler nil :type (or null function)))

;;; Registry structure

(defstruct resource-registry
  "Registry containing both static resources and templates."
  (resources (make-hash-table :test #'equal) :type hash-table)
  (templates (make-hash-table :test #'equal) :type hash-table))

(defvar *global-resource-registry* (make-resource-registry)
  "Global registry of resources.")

;;; Registration functions

(defun register-resource (uri name description handler &key mime-type (registry *global-resource-registry*))
  "Register a static resource in the registry."
  (setf (gethash uri (resource-registry-resources registry))
        (make-resource-entry :uri uri
                             :name name
                             :description description
                             :mime-type mime-type
                             :handler handler))
  uri)

(defun register-resource-template (uri-template name description handler &key mime-type (registry *global-resource-registry*))
  "Register a resource template in the registry."
  (setf (gethash uri-template (resource-registry-templates registry))
        (make-resource-template-entry :uri-template uri-template
                                      :name name
                                      :description description
                                      :mime-type mime-type
                                      :handler handler))
  uri-template)

(defun unregister-resource (uri &optional (registry *global-resource-registry*))
  "Remove a static resource from the registry."
  (remhash uri (resource-registry-resources registry)))

(defun unregister-resource-template (uri-template &optional (registry *global-resource-registry*))
  "Remove a resource template from the registry."
  (remhash uri-template (resource-registry-templates registry)))

;;; Lookup functions

(defun get-resource (uri &optional (registry *global-resource-registry*))
  "Get a static resource entry by URI."
  (gethash uri (resource-registry-resources registry)))

(defun parse-uri-template (template)
  "Parse a URI template into literal segments and parameter names.
Returns (values literals params) where literals has one more element than params."
  (let ((literals nil)
        (params nil)
        (current-start 0)
        (i 0)
        (len (length template)))
    (loop while (< i len) do
      (if (char= (char template i) #\{)
          (let ((end (position #\} template :start i)))
            (if end
                (progn
                  (push (subseq template current-start i) literals)
                  (push (subseq template (1+ i) end) params)
                  (setf current-start (1+ end))
                  (setf i (1+ end)))
                ;; No matching } - treat { as literal and advance
                (incf i)))
          (incf i)))
    (push (subseq template current-start) literals)
    (values (nreverse literals) (nreverse params))))

(defun match-uri-template (template uri)
  "Match URI against a template. Returns alist of (param . value) or NIL."
  (multiple-value-bind (literals params) (parse-uri-template template)
    (let ((pos 0)
          (values nil))
      (loop for i from 0 below (length params)
            for literal = (nth i literals)
            for next-literal = (nth (1+ i) literals)
            do (unless (and (>= (length uri) (+ pos (length literal)))
                            (string= literal (subseq uri pos (+ pos (length literal)))))
                 (return-from match-uri-template nil))
               (incf pos (length literal))
               (let ((end-pos (if (string= next-literal "")
                                  (length uri)
                                  (search next-literal uri :start2 pos))))
                 (unless end-pos
                   (return-from match-uri-template nil))
                 (push (cons (nth i params) (subseq uri pos end-pos)) values)
                 (setf pos end-pos)))
      (let ((final-literal (car (last literals))))
        (unless (and (= pos (- (length uri) (length final-literal)))
                     (string= final-literal (subseq uri pos)))
          (return-from match-uri-template nil)))
      (nreverse values))))

(defun find-matching-template (uri &optional (registry *global-resource-registry*))
  "Find a template that matches the given URI.
Returns (values template-entry matched-params) or NIL."
  (loop for template-entry being the hash-values of (resource-registry-templates registry)
        for template = (resource-template-entry-uri-template template-entry)
        for params = (match-uri-template template uri)
        when params
          return (values template-entry params)))

(defun get-resource-handler (uri &optional (registry *global-resource-registry*))
  "Get the handler for a resource URI (static or template match).
Returns (values handler params) where params is an alist for templates."
  (let ((static (get-resource uri registry)))
    (if static
        (values (resource-entry-handler static) nil)
        (multiple-value-bind (template params) (find-matching-template uri registry)
          (when template
            (values (resource-template-entry-handler template) params))))))

;;; Listing functions

(defun get-all-resources (&optional (registry *global-resource-registry*))
  "Get all static resource entries as a list."
  (loop for entry being the hash-values of (resource-registry-resources registry)
        collect entry))

(defun get-all-resource-templates (&optional (registry *global-resource-registry*))
  "Get all resource template entries as a list."
  (loop for entry being the hash-values of (resource-registry-templates registry)
        collect entry))

(defun resource-entry-to-descriptor (entry)
  "Convert a resource-entry to an MCP resource descriptor hash-table."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "uri" ht) (resource-entry-uri entry))
    (setf (gethash "name" ht) (resource-entry-name entry))
    (when (resource-entry-description entry)
      (setf (gethash "description" ht) (resource-entry-description entry)))
    (when (resource-entry-mime-type entry)
      (setf (gethash "mimeType" ht) (resource-entry-mime-type entry)))
    ht))

(defun template-entry-to-descriptor (entry)
  "Convert a resource-template-entry to an MCP template descriptor hash-table."
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "uriTemplate" ht) (resource-template-entry-uri-template entry))
    (setf (gethash "name" ht) (resource-template-entry-name entry))
    (when (resource-template-entry-description entry)
      (setf (gethash "description" ht) (resource-template-entry-description entry)))
    (when (resource-template-entry-mime-type entry)
      (setf (gethash "mimeType" ht) (resource-template-entry-mime-type entry)))
    ht))

(defun get-all-resource-descriptors (&optional (registry *global-resource-registry*))
  "Get all resource descriptors as a vector for resources/list response."
  (map 'vector #'resource-entry-to-descriptor (get-all-resources registry)))

(defun get-all-template-descriptors (&optional (registry *global-resource-registry*))
  "Get all template descriptors as a vector for resources/templates/list response."
  (map 'vector #'template-entry-to-descriptor (get-all-resource-templates registry)))

(defun clear-resources (&optional (registry *global-resource-registry*))
  "Clear all resources and templates from the registry."
  (clrhash (resource-registry-resources registry))
  (clrhash (resource-registry-templates registry)))

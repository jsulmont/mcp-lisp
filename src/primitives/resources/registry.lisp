;;;; src/primitives/resources/registry.lisp
;;;;
;;;; Resource registry for storing and retrieving resource definitions.

(defpackage #:mcp-lisp/src/primitives/resources/registry
  (:use #:cl)
  (:import-from #:cl-ppcre
                #:create-scanner
                #:scan-to-strings
                #:quote-meta-chars)
  (:import-from #:quri
                #:url-decode)
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
  (handler nil :type (or null function))
  ;; Compiled form, filled in by register-resource-template:
  (scanner nil)                       ; cl-ppcre scanner
  (var-names nil :type list)          ; ordered variable names
  (specificity nil :type list))       ; (literal-chars var-count reserved-count)

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
  "Register a resource template. Compiles the template (signalling on malformed
input) and stores the compiled scanner for matching."
  (multiple-value-bind (scanner vars specificity) (compile-uri-template uri-template)
    (setf (gethash uri-template (resource-registry-templates registry))
          (make-resource-template-entry :uri-template uri-template
                                        :name name
                                        :description description
                                        :mime-type mime-type
                                        :handler handler
                                        :scanner scanner
                                        :var-names vars
                                        :specificity specificity)))
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

(defun parse-var-spec (inner template)
  "Parse a placeholder body INNER into (values name reserved-p).
Supports simple {name} and reserved {+name}; rejects other RFC 6570 operators."
  (let ((op (char inner 0)))
    (multiple-value-bind (name reserved)
        (cond
          ((char= op #\+) (values (subseq inner 1) t))
          ((find op "#./;?&=,!@|")
           (error "Invalid URI template ~s: unsupported operator ~c" template op))
          (t (values inner nil)))
      (when (zerop (length name))
        (error "Invalid URI template ~s: empty variable name" template))
      (unless (every (lambda (c) (or (alphanumericp c) (member c '(#\_ #\- #\.)))) name)
        (error "Invalid URI template ~s: invalid variable name ~s" template name))
      (values name reserved))))

(defun parse-template-tokens (template)
  "Tokenize TEMPLATE into a list of (:literal . string) and (:var name reserved-p).
Signals an error on unbalanced braces, empty/invalid placeholders, unsupported
operators, or adjacent placeholders (two variables with no literal between)."
  (let ((tokens nil) (i 0) (len (length template)) (start 0))
    (flet ((flush (end)
             (when (> end start)
               (push (cons :literal (subseq template start end)) tokens))))
      (loop while (< i len) do
        (cond
          ((char= (char template i) #\{)
           (let ((end (position #\} template :start i)))
             (unless end
               (error "Invalid URI template ~s: unbalanced '{'" template))
             (flush i)
             (let ((inner (subseq template (1+ i) end)))
               (when (zerop (length inner))
                 (error "Invalid URI template ~s: empty placeholder" template))
               (multiple-value-bind (name reserved) (parse-var-spec inner template)
                 (push (list :var name reserved) tokens)))
             (setf i (1+ end) start (1+ end))))
          ((char= (char template i) #\})
           (error "Invalid URI template ~s: unbalanced '}'" template))
          (t (incf i))))
      (flush len))
    (let ((toks (nreverse tokens)))
      (loop for (a b) on toks
            when (and b (eq (car a) :var) (eq (car b) :var))
              do (error "Invalid URI template ~s: adjacent placeholders" template))
      toks)))

(defun compile-uri-template (template)
  "Compile TEMPLATE into (values scanner var-names specificity).
Signals an error on a malformed template. Each simple {var} matches one path
segment ([^/]+); each reserved {+var} matches across segments (.+).
SPECIFICITY is (literal-char-count var-count reserved-count) for ranking."
  (let ((tokens (parse-template-tokens template))
        (out (make-string-output-stream))
        (vars nil) (lit-chars 0) (nvars 0) (nreserved 0))
    (write-char #\^ out)
    (dolist (tok tokens)
      (if (eq (car tok) :literal)
          (progn
            (incf lit-chars (length (cdr tok)))
            (write-string (quote-meta-chars (cdr tok)) out))
          (destructuring-bind (name reserved) (cdr tok)
            (push name vars)
            (incf nvars)
            (when reserved (incf nreserved))
            (write-string (if reserved "(.+)" "([^/]+)") out))))
    (write-char #\$ out)
    (values (create-scanner (get-output-stream-string out))
            (nreverse vars)
            (list lit-chars nvars nreserved))))

(defun match-template-scanner (scanner var-names uri)
  "Match URI with a precompiled SCANNER. Returns (values alist matched-p);
ALIST maps each var name to its percent-decoded captured value. Matching runs
on the raw URI (so %2F can't act as a separator); values are decoded after."
  (multiple-value-bind (whole groups) (scan-to-strings scanner uri)
    (if whole
        (values (loop for name in var-names
                      for val across groups
                      collect (cons name (url-decode val :lenient t)))
                t)
        (values nil nil))))

(defun match-uri-template (template uri)
  "Compile TEMPLATE and match URI; returns an alist of (name . decoded-value),
or NIL. Convenience for ad-hoc matching — the registry uses precompiled scanners."
  (multiple-value-bind (scanner vars) (compile-uri-template template)
    (values (match-template-scanner scanner vars uri))))

(defun template-better-p (entry best)
  "T if template ENTRY is more specific than BEST: more literal chars, then fewer
variables, then fewer reserved variables, then lexicographically smaller template."
  (destructuring-bind (la na ra) (resource-template-entry-specificity entry)
    (destructuring-bind (lb nb rb) (resource-template-entry-specificity best)
      (cond ((/= la lb) (> la lb))
            ((/= na nb) (< na nb))
            ((/= ra rb) (< ra rb))
            (t (and (string< (resource-template-entry-uri-template entry)
                             (resource-template-entry-uri-template best))
                    t))))))

(defun find-matching-template (uri &optional (registry *global-resource-registry*))
  "Find the most specific template matching URI, resolving ambiguity
deterministically (see TEMPLATE-BETTER-P).
Returns (values template-entry matched-params) or NIL."
  (let ((best nil) (best-params nil))
    (maphash
     (lambda (key entry)
       (declare (ignore key))
       (multiple-value-bind (params matched)
           (match-template-scanner (resource-template-entry-scanner entry)
                                   (resource-template-entry-var-names entry)
                                   uri)
         (when (and matched (or (null best) (template-better-p entry best)))
           (setf best entry best-params params))))
     (resource-registry-templates registry))
    (when best (values best best-params))))

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

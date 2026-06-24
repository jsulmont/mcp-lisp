;;;; src/content.lisp
;;;;
;;;; MCP content block utilities.

(defpackage #:mcp-lisp/src/content
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:export #:text-content
           #:image-content
           #:make-content
           #:content-vector))

(in-package #:mcp-lisp/src/content)

(defun text-content (text)
  "Create a text content block."
  (make-ht "type" "text" "text" text))

(defun image-content (data mime-type)
  "Create an image content block with base64 DATA and MIME-TYPE."
  (make-ht "type" "image" "data" data "mimeType" mime-type))

(defun camel-case (string)
  "Convert a kebab/snake STRING to camelCase: \"mime-type\" -> \"mimeType\"."
  (with-output-to-string (out)
    (let ((up nil))
      (loop for ch across string do
        (cond
          ((or (char= ch #\-) (char= ch #\_)) (setf up t))
          (up (write-char (char-upcase ch) out) (setf up nil))
          (t (write-char ch out)))))))

(defun content-field-name (key)
  "MCP field name for KEY. Strings pass through verbatim; keyword/symbol keys are
camelCased so :mime-type -> \"mimeType\" (MCP uses camelCase field names)."
  (if (stringp key)
      key
      (camel-case (string-downcase (symbol-name key)))))

(defun make-content (type &rest args)
  "Create a content block of TYPE with ARGS as a plist.
Keyword keys are camelCased to MCP field names (:mime-type -> \"mimeType\").
Example: (make-content :text :text \"hello\")"
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "type" ht)
          (if (stringp type) type (string-downcase (symbol-name type))))
    (loop for (k v) on args by #'cddr
          do (setf (gethash (content-field-name k) ht) v))
    ht))

(defun content-vector (&rest contents)
  "Create a vector of content blocks from CONTENTS.
Each element can be a hash-table or a string (converted to text content)."
  (map 'vector (lambda (c)
                 (if (stringp c)
                     (text-content c)
                     c))
       contents))

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

(defun make-content (type &rest args)
  "Create a content block of TYPE with ARGS as plist.
Example: (make-content :text :text \"hello\")"
  (let ((ht (make-hash-table :test #'equal)))
    (setf (gethash "type" ht) (string-downcase (symbol-name type)))
    (loop for (k v) on args by #'cddr
          do (setf (gethash (string-downcase (symbol-name k)) ht) v))
    ht))

(defun content-vector (&rest contents)
  "Create a vector of content blocks from CONTENTS.
Each element can be a hash-table or a string (converted to text content)."
  (coerce (mapcar (lambda (c)
                    (if (stringp c)
                        (text-content c)
                        c))
                  contents)
          'vector))

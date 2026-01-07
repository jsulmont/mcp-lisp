;;;; src/json.lisp
;;;;
;;;; JSON encoding/decoding utilities.

(defpackage #:mcp-lisp/src/json
  (:use #:cl)
  (:import-from #:com.inuoe.jzon)
  (:export #:encode-json
           #:decode-json
           #:make-ht))

(in-package #:mcp-lisp/src/json)

(defun make-ht (&rest kvs)
  "Create a hash-table from key-value pairs.
Example: (make-ht \"name\" \"foo\" \"version\" \"1.0\")"
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash k h) v))
    h))

(defun decode-json (string)
  "Parse a JSON STRING into Lisp data structures."
  (com.inuoe.jzon:parse string))

(defun encode-json (object &optional stream)
  "Encode OBJECT as JSON. If STREAM is provided, write to it.
Otherwise return a string."
  (if stream
      (com.inuoe.jzon:stringify object :stream stream)
      (com.inuoe.jzon:stringify object)))

;;;; src/json.lisp
;;;;
;;;; JSON encoding/decoding utilities.

(defpackage #:mcp-lisp/src/json
  (:use #:cl)
  (:import-from #:com.inuoe.jzon)
  (:import-from #:serapeum #:dict)
  (:export #:encode-json
           #:decode-json
           #:dict
           #:make-ht
           #:pp
           #:ht-keys
           #:ht-values
           #:read-json-line
           #:write-json-line))

(in-package #:mcp-lisp/src/json)

(defun make-ht (&rest kvs)
  "Create a hash-table from key-value pairs.
Example: (make-ht \"name\" \"foo\" \"version\" \"1.0\")
Prefer DICT for new code — same semantics with compile-time arity checking."
  (apply #'dict kvs))

(define-compiler-macro make-ht (&rest kvs)
  `(dict ,@kvs))

(defun decode-json (string)
  "Parse a JSON STRING into Lisp data structures."
  (com.inuoe.jzon:parse string
                        :max-string-length (1- array-dimension-limit)))

(defun encode-json (object &optional stream)
  "Encode OBJECT as JSON. If STREAM is provided, write to it.
Otherwise return a string."
  (if stream
      (com.inuoe.jzon:stringify object :stream stream)
      (com.inuoe.jzon:stringify object)))

(defun pp (object)
  "Pretty-print OBJECT as JSON to *standard-output* and return the string.
Useful for inspecting hash-tables, vectors, and nested structures that
print as #<HASH-TABLE ...> with standard CL printing."
  (let ((s (encode-json object)))
    (write-string s)
    (terpri)
    s))

(defun ht-keys (ht)
  "Return a list of keys in hash-table HT."
  (loop for k being the hash-keys of ht collect k))

(defun ht-values (ht)
  "Return a list of values in hash-table HT."
  (loop for v being the hash-values of ht collect v))

(defun read-json-line (stream)
  "Read a line and parse as JSON. Returns NIL on EOF. Skips blank lines."
  (loop for line = (read-line stream nil nil)
        do (cond
             ((null line) (return nil))
             ((string= "" (string-trim '(#\Space #\Tab #\Return) line))
              nil)
             (t (return (decode-json line))))))

(defun write-json-line (object stream)
  "Write OBJECT as JSON followed by newline."
  (encode-json object stream)
  (terpri stream)
  (force-output stream))

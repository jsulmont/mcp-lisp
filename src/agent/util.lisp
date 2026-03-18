;;;; src/agent/util.lisp
;;;;
;;;; Shared utilities for agent modules.

(defpackage #:mcp-lisp/src/agent/util
  (:use #:cl)
  (:export #:read-key-file))

(in-package #:mcp-lisp/src/agent/util)

(defun read-key-file (filename)
  "Read an API key from ~/FILENAME, trimming whitespace. Returns NIL if missing."
  (ignore-errors
    (string-trim '(#\Space #\Newline #\Return #\Tab)
                 (uiop:read-file-string
                  (merge-pathnames filename (user-homedir-pathname))))))

;;;; tests/package.lisp

(defpackage #:mcp-lisp/tests
  (:use #:cl #:fiveam)
  (:export #:mcp-lisp-tests
           #:run-tests))

(in-package #:mcp-lisp/tests)

(def-suite mcp-lisp-tests
  :description "Test suite for mcp-lisp")

(defun run-tests ()
  "Run all mcp-lisp tests."
  (run! 'mcp-lisp-tests))

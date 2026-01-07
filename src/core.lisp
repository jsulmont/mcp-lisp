;;;; src/core.lisp
;;;;
;;;; Core constants and version information for mcp-lisp.

(defpackage #:mcp-lisp/src/core
  (:use #:cl)
  (:export #:+protocol-version+
           #:+supported-protocol-versions+
           #:+sdk-version+
           #:protocol-version>=))

(in-package #:mcp-lisp/src/core)

(defvar +sdk-version+ "0.1.0")

(defvar +protocol-version+ "2025-11-25")

(defparameter +supported-protocol-versions+
  '("2025-11-25" "2025-06-18" "2025-03-26" "2024-11-05")
  "Supported MCP protocol versions in order of preference.")

(defun protocol-version>= (version min-version)
  "Return T if VERSION is greater than or equal to MIN-VERSION.
MCP protocol versions use ISO date format (YYYY-MM-DD), which is lexicographically sortable."
  (and version min-version (string>= version min-version)))

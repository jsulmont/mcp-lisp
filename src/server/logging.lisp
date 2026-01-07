;;;; src/server/logging.lisp
;;;;
;;;; MCP logging support.

(defpackage #:mcp-lisp/src/server/logging
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:invalid-params-error)
  (:export #:*log-level*
           #:*log-levels*
           #:log-level-value
           #:set-log-level
           #:handle-logging-set-level))

(in-package #:mcp-lisp/src/server/logging)

(defvar *log-levels*
  '(("debug" . 0)
    ("info" . 1)
    ("notice" . 2)
    ("warning" . 3)
    ("error" . 4)
    ("critical" . 5)
    ("alert" . 6)
    ("emergency" . 7))
  "Log levels ordered by severity (RFC 5424).")

(defvar *log-level* "info"
  "Current minimum log level.")

(defun log-level-value (level)
  "Get numeric value for a log level string."
  (or (cdr (assoc level *log-levels* :test #'string-equal))
      1))

(defun level-enabled-p (level)
  "Check if a log level is enabled based on current minimum level."
  (>= (log-level-value level) (log-level-value *log-level*)))

(defun set-log-level (level)
  "Set the minimum log level."
  (if (assoc level *log-levels* :test #'string-equal)
      (setf *log-level* level)
      (error "Invalid log level: ~a" level)))

(defun handle-logging-set-level (params)
  "Handle logging/setLevel request. Returns empty hash-table on success."
  (let ((level (and params (gethash "level" params))))
    (cond
      ((null level)
       (error 'invalid-params-error :message "Missing log level"))
      ((not (assoc level *log-levels* :test #'string-equal))
       (error 'invalid-params-error
              :message (format nil "Invalid log level: ~a" level)))
      (t
       (set-log-level level)
       (make-ht)))))

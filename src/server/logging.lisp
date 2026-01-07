;;;; src/server/logging.lisp
;;;;
;;;; MCP logging support.

(defpackage #:mcp-lisp/src/server/logging
  (:use #:cl)
  (:import-from #:jsonrpc)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:export #:*log-level*
           #:*log-levels*
           #:log-level-value
           #:set-log-level
           #:log-message
           #:log-debug
           #:log-info
           #:log-notice
           #:log-warning
           #:log-error
           #:log-critical
           #:log-alert
           #:log-emergency
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

(defun log-message (jsonrpc-server level data &key logger)
  "Send a log message notification to the client."
  (when (and jsonrpc-server (level-enabled-p level))
    (let ((params (make-ht "level" level "data" data)))
      (when logger
        (setf (gethash "logger" params) logger))
      (jsonrpc:notify jsonrpc-server "notifications/message" params))))

(defun log-debug (jsonrpc-server data &key logger)
  "Send a debug log message."
  (log-message jsonrpc-server "debug" data :logger logger))

(defun log-info (jsonrpc-server data &key logger)
  "Send an info log message."
  (log-message jsonrpc-server "info" data :logger logger))

(defun log-notice (jsonrpc-server data &key logger)
  "Send a notice log message."
  (log-message jsonrpc-server "notice" data :logger logger))

(defun log-warning (jsonrpc-server data &key logger)
  "Send a warning log message."
  (log-message jsonrpc-server "warning" data :logger logger))

(defun log-error (jsonrpc-server data &key logger)
  "Send an error log message."
  (log-message jsonrpc-server "error" data :logger logger))

(defun log-critical (jsonrpc-server data &key logger)
  "Send a critical log message."
  (log-message jsonrpc-server "critical" data :logger logger))

(defun log-alert (jsonrpc-server data &key logger)
  "Send an alert log message."
  (log-message jsonrpc-server "alert" data :logger logger))

(defun log-emergency (jsonrpc-server data &key logger)
  "Send an emergency log message."
  (log-message jsonrpc-server "emergency" data :logger logger))

(defun handle-logging-set-level (params)
  "Handle logging/setLevel request. Returns empty hash-table on success."
  (let ((level (and params (gethash "level" params))))
    (cond
      ((null level)
       (error 'jsonrpc:jsonrpc-invalid-params :message "Missing log level"))
      ((not (assoc level *log-levels* :test #'string-equal))
       (error 'jsonrpc:jsonrpc-invalid-params
              :message (format nil "Invalid log level: ~a" level)))
      (t
       (set-log-level level)
       (make-ht)))))

;;;; src/server/logging.lisp
;;;;
;;;; MCP logging: per-session minimum level + notifications/message emission.

(defpackage #:mcp-lisp/src/server/logging
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:import-from #:mcp-lisp/src/conditions
                #:invalid-params-error)
  (:import-from #:mcp-lisp/src/server/state
                #:session-log-level)
  (:export #:*log-levels*
           #:log-level-value
           #:log-enabled-p
           #:send-log
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

(defun log-level-value (level)
  "Numeric severity for a log level name (defaults to info = 1)."
  (or (cdr (assoc level *log-levels* :test #'string-equal)) 1))

(defun session-min-level (session)
  "The numeric minimum level configured for SESSION (info if none)."
  (if session (log-level-value (session-log-level session)) 1))

(defun log-enabled-p (session level)
  "T if a message at LEVEL meets SESSION's configured minimum level."
  (>= (log-level-value level) (session-min-level session)))

(defun send-log (notify-fn session level data &key logger)
  "Send a notifications/message log to the client when LEVEL passes SESSION's
minimum level and NOTIFY-FN is available. DATA is arbitrary JSON-encodable data;
LOGGER is an optional source name. Returns T if sent, NIL if filtered/undeliverable."
  (when (and notify-fn (log-enabled-p session level))
    (let ((params (make-ht "level" level "data" data)))
      (when logger
        (setf (gethash "logger" params) logger))
      (funcall notify-fn "notifications/message" params)
      t)))

(defun handle-logging-set-level (session params)
  "Handle logging/setLevel: set SESSION's minimum log level. Returns {}."
  (let ((level (and params (gethash "level" params))))
    (cond
      ((null level)
       (error 'invalid-params-error :message "Missing log level"))
      ((not (assoc level *log-levels* :test #'string-equal))
       (error 'invalid-params-error
              :message (format nil "Invalid log level: ~a" level)))
      (t
       (setf (session-log-level session) level)
       (make-ht)))))

;;;; src/server/progress.lisp
;;;;
;;;; Progress notification support for long-running operations.

(defpackage #:mcp-lisp/src/server/progress
  (:use #:cl)
  (:import-from #:jsonrpc)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:export #:send-progress
           #:with-progress))

(in-package #:mcp-lisp/src/server/progress)

(defun send-progress (jsonrpc-server progress-token progress &key total message)
  "Send a progress notification to the client.
PROGRESS-TOKEN is the token from the original request.
PROGRESS is the current progress value.
TOTAL is the optional total value (for percentage calculation).
MESSAGE is an optional status message."
  (when (and jsonrpc-server progress-token)
    (let ((params (make-ht "progressToken" progress-token
                           "progress" progress)))
      (when total
        (setf (gethash "total" params) total))
      (when message
        (setf (gethash "message" params) message))
      (jsonrpc:notify jsonrpc-server "notifications/progress" params))))

(defmacro with-progress ((jsonrpc-server progress-token &key (total 100)) &body body)
  "Execute BODY with a progress reporter function available.
Binds REPORT-PROGRESS to a function that takes (progress &key message).

Example:
  (with-progress (server token :total 100)
    (dotimes (i 100)
      (do-work i)
      (report-progress i :message (format nil \"Step ~a\" i))))"
  (let ((server-var (gensym "SERVER"))
        (token-var (gensym "TOKEN"))
        (total-var (gensym "TOTAL")))
    `(let ((,server-var ,jsonrpc-server)
           (,token-var ,progress-token)
           (,total-var ,total))
       (flet ((report-progress (progress &key message)
                (send-progress ,server-var ,token-var progress
                               :total ,total-var
                               :message message)))
         ,@body))))

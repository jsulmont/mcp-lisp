;;;; src/server/progress.lisp
;;;;
;;;; Progress notification support for long-running operations.

(defpackage #:mcp-lisp/src/server/progress
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:export #:send-progress
           #:with-progress))

(in-package #:mcp-lisp/src/server/progress)

(defun send-progress (notify-fn progress-token progress &key total message)
  "Send a progress notification to the client.
NOTIFY-FN is a function that accepts (method params).
PROGRESS-TOKEN is the token from the original request.
PROGRESS is the current progress value.
TOTAL is the optional total value (for percentage calculation).
MESSAGE is an optional status message."
  (when (and notify-fn progress-token)
    (let ((params (make-ht "progressToken" progress-token
                           "progress" progress)))
      (when total
        (setf (gethash "total" params) total))
      (when message
        (setf (gethash "message" params) message))
      (funcall notify-fn "notifications/progress" params))))

(defmacro with-progress ((notify-fn progress-token &key (total 100)) &body body)
  "Execute BODY with a progress reporter function available.
Binds REPORT-PROGRESS to a function that takes (progress &key message).

Example:
  (with-progress (notify-fn token :total 100)
    (dotimes (i 100)
      (do-work i)
      (report-progress i :message (format nil \"Step ~a\" i))))"
  (let ((notify-var (gensym "NOTIFY"))
        (token-var (gensym "TOKEN"))
        (total-var (gensym "TOTAL")))
    `(let ((,notify-var ,notify-fn)
           (,token-var ,progress-token)
           (,total-var ,total))
       (flet ((report-progress (progress &key message)
                (send-progress ,notify-var ,token-var progress
                               :total ,total-var
                               :message message)))
         ,@body))))

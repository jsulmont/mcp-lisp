;;;; src/server/notifications.lisp
;;;;
;;;; Server-to-client notification support.
;;;; Note: Server->client notifications require a notification callback.
;;;; These functions are stubs that can be extended when needed.

(defpackage #:mcp-lisp/src/server/notifications
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:export #:notify-tools-list-changed
           #:notify-prompts-list-changed
           #:notify-resources-list-changed
           #:notify-resource-updated))

(in-package #:mcp-lisp/src/server/notifications)

(defun notify-tools-list-changed (notify-fn)
  "Notify client that the tools list has changed.
NOTIFY-FN should be a function that accepts (method params)."
  (when notify-fn
    (funcall notify-fn "notifications/tools/list_changed" (make-ht))))

(defun notify-prompts-list-changed (notify-fn)
  "Notify client that the prompts list has changed."
  (when notify-fn
    (funcall notify-fn "notifications/prompts/list_changed" (make-ht))))

(defun notify-resources-list-changed (notify-fn)
  "Notify client that the resources list has changed."
  (when notify-fn
    (funcall notify-fn "notifications/resources/list_changed" (make-ht))))

(defun notify-resource-updated (notify-fn uri)
  "Notify client that a specific resource has been updated."
  (when notify-fn
    (funcall notify-fn "notifications/resources/updated"
             (make-ht "uri" uri))))

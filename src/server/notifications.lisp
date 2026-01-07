;;;; src/server/notifications.lisp
;;;;
;;;; Server-to-client notification support.

(defpackage #:mcp-lisp/src/server/notifications
  (:use #:cl)
  (:import-from #:jsonrpc)
  (:import-from #:mcp-lisp/src/json
                #:make-ht)
  (:export #:notify-tools-list-changed
           #:notify-prompts-list-changed
           #:notify-resources-list-changed
           #:notify-resource-updated
           #:send-notification))

(in-package #:mcp-lisp/src/server/notifications)

(defun send-notification (jsonrpc-server method &optional params)
  "Send a notification to the client.
JSONRPC-SERVER is the jsonrpc server instance.
METHOD is the notification method name.
PARAMS is optional parameters hash-table."
  (when jsonrpc-server
    (jsonrpc:notify jsonrpc-server method (or params (make-ht)))))

(defun notify-tools-list-changed (jsonrpc-server)
  "Notify client that the tools list has changed."
  (send-notification jsonrpc-server "notifications/tools/list_changed"))

(defun notify-prompts-list-changed (jsonrpc-server)
  "Notify client that the prompts list has changed."
  (send-notification jsonrpc-server "notifications/prompts/list_changed"))

(defun notify-resources-list-changed (jsonrpc-server)
  "Notify client that the resources list has changed."
  (send-notification jsonrpc-server "notifications/resources/list_changed"))

(defun notify-resource-updated (jsonrpc-server uri)
  "Notify client that a specific resource has been updated."
  (send-notification jsonrpc-server "notifications/resources/updated"
                     (make-ht "uri" uri)))

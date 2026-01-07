;;;; src/primitives/resources/define-resource.lisp
;;;;
;;;; Macros for defining MCP resources declaratively.

(defpackage #:mcp-lisp/src/primitives/resources/define-resource
  (:use #:cl)
  (:import-from #:mcp-lisp/src/primitives/resources/registry
                #:register-resource
                #:register-resource-template
                #:*global-resource-registry*)
  (:export #:define-resource
           #:define-resource-template))

(in-package #:mcp-lisp/src/primitives/resources/define-resource)

(defun uri-has-template-params-p (uri)
  "Check if URI contains template parameters like {name}."
  (and (position #\{ uri) t))

(defmacro define-resource (uri (&key name (mime-type nil)) &body body)
  "Define a static MCP resource.

URI is the resource URI string.
NAME is the display name (defaults to URI).
MIME-TYPE is the optional MIME type string.
BODY should return the resource content as a string or hash-table.

The handler receives (server session) arguments.

Example:
  (define-resource \"config://app/settings\"
    (:name \"App Settings\" :mime-type \"application/json\")
    (encode-json *app-settings*))"
  (let* ((description (if (stringp (car body)) (car body) ""))
         (actual-body (if (stringp (car body)) (cdr body) body))
         (handler-name (gensym "RESOURCE-HANDLER-"))
         (resource-name (or name uri)))
    (when (uri-has-template-params-p uri)
      (error "URI ~s contains template parameters. Use define-resource-template instead." uri))
    `(progn
       (defun ,handler-name (server session)
         (declare (ignorable server session))
         ,@actual-body)
       (register-resource ,uri
                          ,resource-name
                          ,description
                          #',handler-name
                          :mime-type ,mime-type
                          :registry *global-resource-registry*)
       ',uri)))

(defmacro define-resource-template (uri-template (&key name (mime-type nil)) &body body)
  "Define a resource template for dynamic URIs.

URI-TEMPLATE is a URI pattern with {param} placeholders.
NAME is the display name.
MIME-TYPE is the optional MIME type string.
BODY should return the resource content.

The handler receives (server session params) where params is an alist
of (param-name . value) extracted from the URI.

Example:
  (define-resource-template \"file:///{path}\"
    (:name \"Local Files\" :mime-type \"text/plain\")
    (let ((path (cdr (assoc \"path\" params :test #'string=))))
      (uiop:read-file-string (concatenate 'string \"/\" path))))"
  (let* ((description (if (stringp (car body)) (car body) ""))
         (actual-body (if (stringp (car body)) (cdr body) body))
         (handler-name (gensym "TEMPLATE-HANDLER-"))
         (resource-name (or name uri-template)))
    (unless (uri-has-template-params-p uri-template)
      (error "URI template ~s has no parameters. Use define-resource instead." uri-template))
    `(progn
       (defun ,handler-name (server session params)
         (declare (ignorable server session params))
         ,@actual-body)
       (register-resource-template ,uri-template
                                   ,resource-name
                                   ,description
                                   #',handler-name
                                   :mime-type ,mime-type
                                   :registry *global-resource-registry*)
       ',uri-template)))

;;;; src/a2a/messages.lisp
;;;;
;;;; A2A Messages - communication between agents.

(defpackage #:mcp-lisp/src/a2a/messages
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht
                #:encode-json)
  (:export #:make-message
           #:make-text-part
           #:make-file-part
           #:make-data-part
           #:message-role
           #:message-parts
           #:message-to-ht))

(in-package #:mcp-lisp/src/a2a/messages)

(defclass message ()
  ((role :initarg :role
         :reader message-role
         :type string)
   (parts :initarg :parts
          :reader message-parts
          :type list))
  (:documentation "A2A Message - a communication turn."))

(defun make-message (role parts)
  "Create a message. ROLE is 'user' or 'agent'. PARTS is a list of content parts."
  (make-instance 'message :role role :parts parts))

(defun make-text-part (text)
  "Create a text content part."
  (make-ht "type" "text" "text" text))

(defun make-file-part (uri &key mime-type name)
  "Create a file reference part."
  (let ((ht (make-ht "type" "file" "uri" uri)))
    (when mime-type (setf (gethash "mimeType" ht) mime-type))
    (when name (setf (gethash "name" ht) name))
    ht))

(defun make-data-part (data &key mime-type)
  "Create a structured data part."
  (let ((ht (make-ht "type" "data" "data" data)))
    (when mime-type (setf (gethash "mimeType" ht) mime-type))
    ht))

(defun message-to-ht (message)
  "Convert message to hash-table for JSON serialization."
  (make-ht "role" (message-role message)
           "parts" (message-parts message)))

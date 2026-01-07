;;;; src/a2a/skills.lisp
;;;;
;;;; A2A Skills - capabilities an agent exposes to other agents.

(defpackage #:mcp-lisp/src/a2a/skills
  (:use #:cl)
  (:import-from #:mcp-lisp/src/a2a/agent-card
                #:*agent-card*
                #:add-skill-to-card)
  (:export #:*skill-registry*
           #:define-skill
           #:get-skill
           #:invoke-skill))

(in-package #:mcp-lisp/src/a2a/skills)

(defvar *skill-registry* (make-hash-table :test #'equal)
  "Registry of defined skills.")

(defun register-skill (id name description handler)
  "Register a skill in the registry."
  (setf (gethash id *skill-registry*)
        (list :id id
              :name name
              :description description
              :handler handler))
  (when *agent-card*
    (add-skill-to-card *agent-card* :id id :name name :description description)))

(defun get-skill (id)
  "Get a skill by ID."
  (gethash id *skill-registry*))

(defun invoke-skill (id message)
  "Invoke a skill with a message. Returns result or signals error."
  (let ((skill (get-skill id)))
    (unless skill
      (error "Unknown skill: ~a" id))
    (funcall (getf skill :handler) message)))

(defmacro define-skill (name (&key description) &body body)
  "Define a skill that can be invoked by other agents.
NAME is both the skill ID and the function name.
BODY receives MESSAGE as its argument."
  (let ((id (string-downcase (symbol-name name)))
        (display-name (string-capitalize (substitute #\Space #\- (symbol-name name))))
        (message-sym (intern "MESSAGE")))
    `(progn
       (defun ,name (,message-sym)
         ,@body)
       (register-skill ,id ,display-name ,description #',name))))

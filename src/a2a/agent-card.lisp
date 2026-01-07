;;;; src/a2a/agent-card.lisp
;;;;
;;;; A2A Agent Card - discovery metadata for agents.

(defpackage #:mcp-lisp/src/a2a/agent-card
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht
                #:encode-json)
  (:export #:*agent-card*
           #:agent-card
           #:make-agent-card
           #:define-agent-card
           #:agent-card-to-json
           #:agent-card-id
           #:agent-card-name
           #:agent-card-description
           #:agent-card-service-url
           #:agent-card-skills
           #:add-skill-to-card))

(in-package #:mcp-lisp/src/a2a/agent-card)

(defvar *agent-card* nil
  "The current agent's card.")

(defclass agent-card ()
  ((id :initarg :id
       :accessor agent-card-id
       :type string)
   (name :initarg :name
         :accessor agent-card-name
         :type string)
   (description :initarg :description
                :initform nil
                :accessor agent-card-description
                :type (or null string))
   (provider-name :initarg :provider-name
                  :initform "mcp-lisp"
                  :accessor agent-card-provider-name
                  :type string)
   (provider-url :initarg :provider-url
                 :initform nil
                 :accessor agent-card-provider-url
                 :type (or null string))
   (service-url :initarg :service-url
                :accessor agent-card-service-url
                :type string)
   (skills :initarg :skills
           :initform nil
           :accessor agent-card-skills
           :type list)
   (content-types :initarg :content-types
                  :initform '("text/plain" "application/json")
                  :accessor agent-card-content-types
                  :type list)
   (streaming :initarg :streaming
              :initform t
              :accessor agent-card-streaming-p
              :type boolean)
   (push-notifications :initarg :push-notifications
                       :initform nil
                       :accessor agent-card-push-notifications-p
                       :type boolean))
  (:documentation "A2A Agent Card metadata."))

(defun make-agent-card (&key id name description
                             (provider-name "mcp-lisp")
                             provider-url
                             service-url
                             skills
                             (content-types '("text/plain" "application/json"))
                             (streaming t)
                             (push-notifications nil))
  "Create a new agent card."
  (make-instance 'agent-card
                 :id id
                 :name name
                 :description description
                 :provider-name provider-name
                 :provider-url provider-url
                 :service-url service-url
                 :skills skills
                 :content-types content-types
                 :streaming streaming
                 :push-notifications push-notifications))

(defun skill-to-ht (skill)
  "Convert a skill plist to hash-table."
  (let ((ht (make-ht "id" (getf skill :id)
                     "name" (getf skill :name))))
    (when (getf skill :description)
      (setf (gethash "description" ht) (getf skill :description)))
    ht))

(defun agent-card-to-ht (card)
  "Convert agent card to hash-table for JSON serialization."
  (let ((ht (make-ht
             "id" (agent-card-id card)
             "name" (agent-card-name card)
             "provider" (make-ht "name" (agent-card-provider-name card))
             "capabilities" (make-ht
                             "skills" (mapcar #'skill-to-ht (agent-card-skills card))
                             "contentTypes" (agent-card-content-types card)
                             "streaming" (agent-card-streaming-p card)
                             "pushNotifications" (agent-card-push-notifications-p card))
             "interface" (make-ht
                          "serviceUrl" (agent-card-service-url card)
                          "protocols" (list "a2a/1.0")))))
    (when (agent-card-description card)
      (setf (gethash "description" ht) (agent-card-description card)))
    (when (agent-card-provider-url card)
      (setf (gethash "url" (gethash "provider" ht)) (agent-card-provider-url card)))
    ht))

(defun agent-card-to-json (card)
  "Convert agent card to JSON string."
  (encode-json (agent-card-to-ht card)))

(defun add-skill-to-card (card &key id name description)
  "Add a skill to an agent card."
  (push (list :id id :name name :description description)
        (agent-card-skills card)))

(defmacro define-agent-card ((&key id name description
                                   (provider-name "mcp-lisp")
                                   provider-url
                                   service-url
                                   (content-types ''("text/plain" "application/json"))
                                   (streaming t)
                                   (push-notifications nil)))
  "Define the agent card for this agent and set *agent-card*."
  `(setf *agent-card*
         (make-agent-card :id ,id
                          :name ,name
                          :description ,description
                          :provider-name ,provider-name
                          :provider-url ,provider-url
                          :service-url ,service-url
                          :content-types ,content-types
                          :streaming ,streaming
                          :push-notifications ,push-notifications)))

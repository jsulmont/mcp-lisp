;;;; src/a2a/tasks.lisp
;;;;
;;;; A2A Tasks - unit of work with lifecycle management.

(defpackage #:mcp-lisp/src/a2a/tasks
  (:use #:cl)
  (:import-from #:mcp-lisp/src/json
                #:make-ht
                #:encode-json)
  (:export #:*task-registry*
           #:task
           #:make-task
           #:task-id
           #:task-status
           #:task-artifacts
           #:task-messages
           #:get-task
           #:create-task
           #:update-task-status
           #:add-task-artifact
           #:add-task-message
           #:cancel-task
           #:task-to-ht))

(in-package #:mcp-lisp/src/a2a/tasks)

(defvar *task-registry* (make-hash-table :test #'equal)
  "Registry of active tasks.")

(defvar *task-counter* 0
  "Counter for generating task IDs.")

(defclass task ()
  ((id :initarg :id
       :reader task-id
       :type string)
   (status :initarg :status
           :initform :pending
           :accessor task-status
           :type keyword)
   (artifacts :initarg :artifacts
              :initform nil
              :accessor task-artifacts
              :type list)
   (messages :initarg :messages
             :initform nil
             :accessor task-messages
             :type list)
   (created-at :initarg :created-at
               :reader task-created-at)
   (updated-at :initarg :updated-at
               :accessor task-updated-at))
  (:documentation "A2A Task - a unit of work."))

(defun generate-task-id ()
  "Generate a unique task ID."
  (format nil "task-~a-~a" (get-universal-time) (incf *task-counter*)))

(defun make-task (&key (id (generate-task-id)) (status :pending) messages)
  "Create a new task."
  (let ((now (get-universal-time)))
    (make-instance 'task
                   :id id
                   :status status
                   :messages messages
                   :created-at now
                   :updated-at now)))

(defun create-task (&key messages)
  "Create and register a new task."
  (let ((task (make-task :messages messages)))
    (setf (gethash (task-id task) *task-registry*) task)
    task))

(defun get-task (id)
  "Get a task by ID."
  (gethash id *task-registry*))

(defun update-task-status (task new-status)
  "Update task status. Valid statuses: :pending :working :completed :failed :canceled"
  (setf (task-status task) new-status)
  (setf (task-updated-at task) (get-universal-time))
  task)

(defun add-task-artifact (task artifact)
  "Add an artifact to a task."
  (push artifact (task-artifacts task))
  (setf (task-updated-at task) (get-universal-time))
  task)

(defun add-task-message (task message)
  "Add a message to a task's history."
  (push message (task-messages task))
  (setf (task-updated-at task) (get-universal-time))
  task)

(defun cancel-task (task)
  "Cancel a task if it's not already in a terminal state."
  (unless (member (task-status task) '(:completed :failed :canceled))
    (update-task-status task :canceled))
  task)

(defun status-to-string (status)
  "Convert status keyword to A2A status string."
  (ecase status
    (:pending "pending")
    (:working "working")
    (:completed "completed")
    (:failed "failed")
    (:canceled "canceled")))

(defun task-to-ht (task)
  "Convert task to hash-table for JSON serialization."
  (make-ht "id" (task-id task)
           "status" (status-to-string (task-status task))
           "artifacts" (coerce (reverse (task-artifacts task)) 'vector)
           "messages" (coerce (reverse (task-messages task)) 'vector)))

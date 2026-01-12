;;;; tests/a2a-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite a2a-tests
  :description "Tests for A2A protocol implementation"
  :in mcp-lisp-tests)

(in-suite a2a-tests)

;;; Task tests

(test task-creation
  "create-task creates a task with generated ID"
  (let ((mcp-lisp/src/a2a/tasks::*task-registry* (make-hash-table :test #'equal)))
    (let ((task (mcp-lisp/src/a2a/tasks:create-task)))
      (is (not (null (mcp-lisp/src/a2a/tasks:task-id task))))
      (is (eq :pending (mcp-lisp/src/a2a/tasks:task-status task))))))

(test task-status-update
  "update-task-status changes task status"
  (let ((mcp-lisp/src/a2a/tasks::*task-registry* (make-hash-table :test #'equal)))
    (let ((task (mcp-lisp/src/a2a/tasks:create-task)))
      (mcp-lisp/src/a2a/tasks:update-task-status task :working)
      (is (eq :working (mcp-lisp/src/a2a/tasks:task-status task)))
      (mcp-lisp/src/a2a/tasks:update-task-status task :completed)
      (is (eq :completed (mcp-lisp/src/a2a/tasks:task-status task))))))

(test task-cancel
  "cancel-task transitions non-terminal tasks to canceled"
  (let ((mcp-lisp/src/a2a/tasks::*task-registry* (make-hash-table :test #'equal)))
    (let ((task (mcp-lisp/src/a2a/tasks:create-task)))
      (mcp-lisp/src/a2a/tasks:update-task-status task :working)
      (mcp-lisp/src/a2a/tasks:cancel-task task)
      (is (eq :canceled (mcp-lisp/src/a2a/tasks:task-status task))))))

(test task-cancel-completed-noop
  "cancel-task does not change completed tasks"
  (let ((mcp-lisp/src/a2a/tasks::*task-registry* (make-hash-table :test #'equal)))
    (let ((task (mcp-lisp/src/a2a/tasks:create-task)))
      (mcp-lisp/src/a2a/tasks:update-task-status task :completed)
      (mcp-lisp/src/a2a/tasks:cancel-task task)
      (is (eq :completed (mcp-lisp/src/a2a/tasks:task-status task))))))

(test task-artifacts-fifo-order
  "task-to-ht returns artifacts in FIFO order (creation order)"
  (let ((mcp-lisp/src/a2a/tasks::*task-registry* (make-hash-table :test #'equal)))
    (let ((task (mcp-lisp/src/a2a/tasks:create-task)))
      (mcp-lisp/src/a2a/tasks:add-task-artifact task (mcp-lisp:make-ht "index" 1))
      (mcp-lisp/src/a2a/tasks:add-task-artifact task (mcp-lisp:make-ht "index" 2))
      (mcp-lisp/src/a2a/tasks:add-task-artifact task (mcp-lisp:make-ht "index" 3))
      (let* ((ht (mcp-lisp/src/a2a/tasks:task-to-ht task))
             (artifacts (gethash "artifacts" ht)))
        ;; Should be in creation order: 1, 2, 3
        (is (= 1 (gethash "index" (aref artifacts 0))))
        (is (= 2 (gethash "index" (aref artifacts 1))))
        (is (= 3 (gethash "index" (aref artifacts 2))))))))

(test task-messages-fifo-order
  "task-to-ht returns messages in FIFO order (creation order)"
  (let ((mcp-lisp/src/a2a/tasks::*task-registry* (make-hash-table :test #'equal)))
    (let ((task (mcp-lisp/src/a2a/tasks:create-task)))
      (mcp-lisp/src/a2a/tasks:add-task-message task (mcp-lisp:make-ht "index" 1))
      (mcp-lisp/src/a2a/tasks:add-task-message task (mcp-lisp:make-ht "index" 2))
      (mcp-lisp/src/a2a/tasks:add-task-message task (mcp-lisp:make-ht "index" 3))
      (let* ((ht (mcp-lisp/src/a2a/tasks:task-to-ht task))
             (messages (gethash "messages" ht)))
        ;; Should be in creation order: 1, 2, 3
        (is (= 1 (gethash "index" (aref messages 0))))
        (is (= 2 (gethash "index" (aref messages 1))))
        (is (= 3 (gethash "index" (aref messages 2))))))))

(test task-get-by-id
  "get-task retrieves task by ID"
  (let ((mcp-lisp/src/a2a/tasks::*task-registry* (make-hash-table :test #'equal)))
    (let* ((task (mcp-lisp/src/a2a/tasks:create-task))
           (id (mcp-lisp/src/a2a/tasks:task-id task))
           (retrieved (mcp-lisp/src/a2a/tasks:get-task id)))
      (is (eq task retrieved)))))

(test task-get-nonexistent
  "get-task returns nil for unknown ID"
  (let ((mcp-lisp/src/a2a/tasks::*task-registry* (make-hash-table :test #'equal)))
    (is (null (mcp-lisp/src/a2a/tasks:get-task "nonexistent-id")))))

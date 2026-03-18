;;;; tests/worker-pool-tests.lisp

(in-package #:mcp-lisp/tests)

(def-suite worker-pool-tests
  :description "Tests for the fixed-size worker pool"
  :in mcp-lisp-tests)

(in-suite worker-pool-tests)

;;; Aliases for brevity
(defmacro with-pool ((var size) &body body)
  `(let ((,var (mcp-lisp/src/transport/worker-pool:make-worker-pool ,size)))
     (unwind-protect (progn ,@body)
       (mcp-lisp/src/transport/worker-pool:stop-worker-pool ,var))))

(test make-worker-pool-creates-threads
  "make-worker-pool creates the requested number of live threads"
  (with-pool (pool 3)
    (is (= 3 (mcp-lisp/src/transport/worker-pool:worker-pool-size pool)))
    (is (mcp-lisp/src/transport/worker-pool:worker-pool-running-p pool))))

(test make-worker-pool-rejects-zero
  "make-worker-pool signals an error when size is 0"
  (signals error
    (mcp-lisp/src/transport/worker-pool:make-worker-pool 0)))

(test submit-executes-thunk
  "submit-to-pool executes the submitted thunk"
  (with-pool (pool 2)
    (let ((result nil)
          (lock (bt:make-lock "test"))
          (cv (bt:make-condition-variable)))
      (mcp-lisp/src/transport/worker-pool:submit-to-pool
       pool
       (lambda ()
         (bt:with-lock-held (lock)
           (setf result 42)
           (bt:condition-notify cv))))
      (bt:with-lock-held (lock)
        (loop until result
              do (bt:condition-wait cv lock :timeout 5)))
      (is (= 42 result)))))

(test submit-multiple-tasks
  "Multiple submitted tasks all execute"
  (with-pool (pool 2)
    (let ((counter 0)
          (lock (bt:make-lock "test"))
          (cv (bt:make-condition-variable))
          (target 20))
      (dotimes (_ target)
        (mcp-lisp/src/transport/worker-pool:submit-to-pool
         pool
         (lambda ()
           (bt:with-lock-held (lock)
             (incf counter)
             (when (= counter target)
               (bt:condition-notify cv))))))
      (bt:with-lock-held (lock)
        (loop until (= counter target)
              do (bt:condition-wait cv lock :timeout 5)))
      (is (= target counter)))))

(test submit-preserves-order-single-worker
  "With 1 worker, tasks execute in submission order"
  (with-pool (pool 1)
    (let ((results nil)
          (lock (bt:make-lock "test"))
          (cv (bt:make-condition-variable))
          (target 5))
      (dotimes (i target)
        (let ((val i))
          (mcp-lisp/src/transport/worker-pool:submit-to-pool
           pool
           (lambda ()
             (bt:with-lock-held (lock)
               (push val results)
               (when (= (length results) target)
                 (bt:condition-notify cv)))))))
      (bt:with-lock-held (lock)
        (loop until (= (length results) target)
              do (bt:condition-wait cv lock :timeout 5)))
      (is (equal '(0 1 2 3 4) (nreverse results))))))

(test stop-worker-pool-terminates-threads
  "stop-worker-pool stops all worker threads"
  (let ((pool (mcp-lisp/src/transport/worker-pool:make-worker-pool 3)))
    (is (mcp-lisp/src/transport/worker-pool:worker-pool-running-p pool))
    (mcp-lisp/src/transport/worker-pool:stop-worker-pool pool)
    (is (not (mcp-lisp/src/transport/worker-pool:worker-pool-running-p pool)))))

(test submit-after-stop-signals-error
  "Submitting to a stopped pool signals an error"
  (let ((pool (mcp-lisp/src/transport/worker-pool:make-worker-pool 1)))
    (mcp-lisp/src/transport/worker-pool:stop-worker-pool pool)
    (signals error
      (mcp-lisp/src/transport/worker-pool:submit-to-pool
       pool (lambda () nil)))))

(test worker-survives-handler-error
  "A task error doesn't kill the worker thread"
  (with-pool (pool 1)
    (let ((result nil)
          (lock (bt:make-lock "test"))
          (cv (bt:make-condition-variable)))
      ;; First task: errors
      (mcp-lisp/src/transport/worker-pool:submit-to-pool
       pool (lambda () (error "boom")))
      (sleep 0.1)
      ;; Second task: must still run
      (mcp-lisp/src/transport/worker-pool:submit-to-pool
       pool
       (lambda ()
         (bt:with-lock-held (lock)
           (setf result :survived)
           (bt:condition-notify cv))))
      (bt:with-lock-held (lock)
        (loop until result
              do (bt:condition-wait cv lock :timeout 5)))
      (is (eq :survived result)))))

(test concurrent-submits
  "Concurrent submits from multiple threads all complete"
  (with-pool (pool 4)
    (let ((counter 0)
          (lock (bt:make-lock "test"))
          (cv (bt:make-condition-variable))
          (submitters 4)
          (tasks-per 10)
          (target (* 4 10)))
      ;; Spawn multiple threads that each submit tasks
      (dotimes (_ submitters)
        (bt:make-thread
         (lambda ()
           (dotimes (_ tasks-per)
             (mcp-lisp/src/transport/worker-pool:submit-to-pool
              pool
              (lambda ()
                (bt:with-lock-held (lock)
                  (incf counter)
                  (when (= counter target)
                    (bt:condition-notify cv)))))))))
      (bt:with-lock-held (lock)
        (loop until (= counter target)
              do (bt:condition-wait cv lock :timeout 10)))
      (is (= target counter)))))

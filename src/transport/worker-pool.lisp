;;;; src/transport/worker-pool.lisp
;;;;
;;;; Fixed-size thread pool for dispatching blocking work off event-loop threads.

(defpackage #:mcp-lisp/src/transport/worker-pool
  (:use #:cl)
  (:import-from #:bordeaux-threads)
  (:export #:worker-pool
           #:make-worker-pool
           #:submit-to-pool
           #:stop-worker-pool
           #:worker-pool-size
           #:worker-pool-running-p))

(in-package #:mcp-lisp/src/transport/worker-pool)

(defstruct (worker-pool (:constructor %make-worker-pool))
  "Fixed-size thread pool. Workers block on a condition variable until work
is enqueued via SUBMIT-TO-POOL.  Graceful shutdown via STOP-WORKER-POOL."
  (queue   (sb-concurrency:make-queue :name "worker-pool") :type sb-concurrency:queue :read-only t)
  (lock    (bt:make-lock "worker-pool")    :read-only t)
  (cv      (bt:make-condition-variable :name "worker-pool-cv") :read-only t)
  (threads nil   :type list)
  (size    0     :type fixnum :read-only t)
  (stop    nil   :type boolean))

(defun worker-loop (pool)
  "Drain the queue until the pool is stopped.  Each iteration either
dequeues and runs a thunk, or blocks on the CV with a 1 s timeout
so the stop flag is eventually seen even if a notify is missed."
  (loop until (worker-pool-stop pool)
        do (let ((thunk (sb-concurrency:dequeue (worker-pool-queue pool))))
             (if thunk
                 (handler-case (funcall thunk)
                   (error (e)
                     (log:debug "Worker pool task error: ~a" e)))
                 (bt:with-lock-held ((worker-pool-lock pool))
                   (unless (worker-pool-stop pool)
                     (bt:condition-wait (worker-pool-cv pool)
                                        (worker-pool-lock pool)
                                        :timeout 1)))))))

(defun make-worker-pool (size &key (name "mcp-worker"))
  "Create and start a pool of SIZE worker threads.
SIZE must be at least 1."
  (assert (plusp size) (size) "Worker pool size must be positive, got ~a" size)
  (let ((pool (%make-worker-pool :size size)))
    (setf (worker-pool-threads pool)
          (loop for i from 0 below size
                collect (bt:make-thread
                          (lambda () (worker-loop pool))
                          :name (format nil "~a-~d" name i))))
    pool))

(defun submit-to-pool (pool thunk)
  "Submit THUNK for execution on a pool worker thread.  Returns T immediately.
Signals an error if the pool has been stopped."
  (when (worker-pool-stop pool)
    (error "Cannot submit to a stopped worker pool"))
  (sb-concurrency:enqueue thunk (worker-pool-queue pool))
  (bt:with-lock-held ((worker-pool-lock pool))
    (bt:condition-notify (worker-pool-cv pool)))
  t)

(defun stop-worker-pool (pool &key (timeout 5))
  "Stop the worker pool.  Sets the stop flag, wakes all workers, then
waits up to TIMEOUT seconds for them to exit gracefully.  Any threads
still alive after the deadline are forcefully destroyed."
  (setf (worker-pool-stop pool) t)
  ;; Wake all workers so they see the stop flag
  (bt:with-lock-held ((worker-pool-lock pool))
    (dotimes (_ (worker-pool-size pool))
      (bt:condition-notify (worker-pool-cv pool))))
  ;; Poll until all threads exit or deadline passes
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop while (and (< (get-internal-real-time) deadline)
                     (some #'bt:thread-alive-p (worker-pool-threads pool)))
          do (sleep 0.05)))
  ;; Force-kill any stragglers
  (dolist (thread (worker-pool-threads pool))
    (when (bt:thread-alive-p thread)
      (ignore-errors (bt:destroy-thread thread))))
  (setf (worker-pool-threads pool) nil)
  t)

(defun worker-pool-running-p (pool)
  "Return T if the pool has not been stopped and has live worker threads."
  (and (not (worker-pool-stop pool))
       (worker-pool-threads pool)
       (some #'bt:thread-alive-p (worker-pool-threads pool))))

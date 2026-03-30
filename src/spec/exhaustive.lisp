(defpackage #:mcp-lisp/src/spec/exhaustive
  (:use #:cl #:screamer)
  (:shadowing-import-from #:screamer #:defun #:multiple-value-bind #:y-or-n-p)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*config*)
  (:import-from #:mcp-lisp/src/spec/introspection
                #:entity-variants
                #:list-rules
                #:describe-rule)
  (:import-from #:mcp-lisp/src/spec/transitions
                #:detect-state-fields
                #:field-default)
  (:import-from #:mcp-lisp/src/spec/checking
                #:invariants-for
                #:check-invariants)
  (:import-from #:mcp-lisp/src/spec/generation
                #:generate-instance
                #:ensure-entity-accessors
                #:ensure-variant-accessors
                #:ensure-config-accessor)
  (:import-from #:mcp-lisp/src/spec/rules
                #:applicable-rules
                #:apply-rule)
  (:export #:exhaustive-walk))

(in-package #:mcp-lisp/src/spec/exhaustive)

(defun state-key (instance state-fields)
  (mapcar (lambda (sf) (getf instance sf)) state-fields))

(defun has-after-rules-p (entity-name)
  (dolist (rname (list-rules))
    (let* ((rule (describe-rule rname))
           (when-clause (getf rule :when)))
      (when (and when-clause (symbolp (car when-clause))
                 (string-equal (symbol-name (car when-clause))
                               (string entity-name))
                 (getf rule :after))
        (return t)))))

(defun walk-step (entity-name instance depth max-depth trace
                  state-fields use-clock now clock-step
                  visited violations paths)
  (when (>= depth max-depth)
    (incf (aref paths 0))
    (return-from walk-step nil))
  (let ((rules (applicable-rules entity-name instance)))
    (when (null rules)
      (incf (aref paths 0))
      (return-from walk-step nil))
    (let* ((now (if use-clock (+ now clock-step) now))
           (rname (a-member-of rules)))
      (multiple-value-bind (new-instance ok _reason)
          (apply-rule entity-name instance rname
                      :now (when use-clock now))
        (declare (ignore _reason))
        (unless ok (fail))
        (let* ((r (check-invariants entity-name new-instance))
               (violated (when (eq (car r) :fail) (cdr r))))
          (when violated
            (push (list :step (1+ depth)
                        :after rname
                        :violated violated
                        :instance (copy-list new-instance)
                        :trace (reverse (cons rname trace)))
                  (aref violations 0))
            (fail))
          (let ((sk (cons (1+ depth) (state-key new-instance state-fields))))
            (when (gethash sk visited)
              (incf (aref paths 0))
              (return-from walk-step nil))
            (setf (gethash sk visited) t)
            (walk-step entity-name new-instance (1+ depth) max-depth
                       (cons rname trace)
                       state-fields use-clock now clock-step
                       visited violations paths)))))))

(cl:defun exhaustive-walk (entity-name &key (depth 10) (verbose t)
                                            (clock-start 0) (clock-step 10))
  (ensure-entity-accessors entity-name)
  (dolist (vname (entity-variants entity-name))
    (ensure-variant-accessors vname))
  (when *config* (ensure-config-accessor))
  (let* ((state-fields (detect-state-fields entity-name))
         (use-clock (has-after-rules-p entity-name))
         (overrides (let ((ov nil))
                      (dolist (sf state-fields ov)
                        (let ((default (field-default entity-name sf)))
                          (when default
                            (push default ov)
                            (push sf ov))))))
         (initial (generate-instance entity-name overrides))
         (visited (make-hash-table :test #'equal))
         (violations (vector nil))
         (paths (vector 0)))
    (let* ((init-r (check-invariants entity-name initial))
           (init-v (when (eq (car init-r) :fail) (cdr init-r))))
      (when init-v
        (let ((result (list :entity entity-name
                            :depth depth
                            :paths-explored 0
                            :states-visited 0
                            :violations (list (list :step 0
                                                    :after "initial"
                                                    :violated init-v
                                                    :instance (copy-list initial)
                                                    :trace nil))
                            :status :fail)))
          (when verbose (print-results result))
          (return-from exhaustive-walk result))))
    (for-effects
      (walk-step entity-name initial 0 depth nil
                 state-fields use-clock clock-start clock-step
                 visited violations paths))
    (let* ((found (nreverse (aref violations 0)))
           (result (list :entity entity-name
                         :depth depth
                         :paths-explored (aref paths 0)
                         :states-visited (hash-table-count visited)
                         :violations found
                         :status (if found :fail :pass))))
      (when verbose (print-results result))
      result)))

(cl:defun print-results (result)
  (let ((entity (getf result :entity))
        (depth (getf result :depth))
        (paths (getf result :paths-explored))
        (states (getf result :states-visited))
        (violations (getf result :violations))
        (inv-count (length (invariants-for (getf result :entity)))))
    (format t "~%=== Exhaustive Walk Results ===~%")
    (format t "  ~A (~A invariants, depth ~A)~%" entity inv-count depth)
    (format t "  ~A paths explored, ~A distinct states visited~%" paths states)
    (if (null violations)
        (format t "  NO VIOLATIONS FOUND~%")
        (progn
          (format t "  ~A VIOLATION~:P:~%" (length violations))
          (dolist (v violations)
            (format t "    step ~A after ~A~@[ (trace: ~{~A~^ → ~})~]:~%"
                    (getf v :step) (getf v :after) (getf v :trace))
            (dolist (name (getf v :violated))
              (format t "      ~A~%" name)))))))

(defpackage #:mcp-lisp/src/spec/checking
  (:use #:cl)
  (:import-from #:mcp-lisp/src/spec/registry
                #:*invariants*
                #:*variants*
                #:*config*
                #:*current-config*
                #:*scenarios*)
  (:import-from #:mcp-lisp/src/spec/introspection
                #:describe-entity
                #:describe-invariant
                #:list-invariants
                #:describe-variant
                #:entity-variants
                #:list-variants
                #:describe-scenario)
  (:import-from #:mcp-lisp/src/spec/pbt-util
                #:get-compiled-fn)
  (:export #:invariants-for
           #:variant-invariants-for
           #:check-invariants
           #:scenario-invariants-for
           #:check-scenario-invariants
           #:config-invariants
           #:check-config-invariants))

(in-package #:mcp-lisp/src/spec/checking)

(defun invariants-for (entity-name)
  "Return a list of (inv-name inv-plist) for invariants that apply to ENTITY-NAME."
  (let* ((entity (describe-entity entity-name))
         (entity-sym (getf entity :name)))
    (loop for inv-name in (list-invariants)
          for inv = (describe-invariant inv-name)
          when (string-equal (symbol-name (getf inv :on))
                             (symbol-name entity-sym))
            collect (list inv-name inv))))

(defun variant-invariants-for (variant-name)
  "Return a list of (inv-name inv-plist) for invariants whose :on matches VARIANT-NAME."
  (let ((vname (string-downcase (string variant-name))))
    (loop for inv-name in (list-invariants)
          for inv = (describe-invariant inv-name)
          when (string-equal (string-downcase (symbol-name (getf inv :on)))
                             vname)
            collect (list inv-name inv))))

(defun check-invariants (entity-name instance)
  "Check all invariants for ENTITY-NAME against INSTANCE.
Also checks variant-specific invariants when the discriminator matches.
Returns (:PASS) when all invariants hold, or (:FAIL inv1 inv2 ...) with
the names of violated invariants."
  (let ((violations nil))
    ;; Base entity invariants
    (dolist (entry (invariants-for entity-name))
      (destructuring-bind (inv-name inv) entry
        (let ((on-sym (getf inv :on))
              (check-form (getf inv :check)))
          (handler-case
              (let ((fn (get-compiled-fn inv-name (list on-sym) check-form)))
                (unless (funcall fn instance)
                  (push inv-name violations)))
            (error (e)
              (push (format nil "~A (error: ~A)" inv-name e) violations))))))
    ;; :present-when field constraints
    (let ((fields (getf (describe-entity entity-name) :fields)))
      (dolist (field fields)
        (let* ((fname (first field))
               (key (intern (symbol-name fname) :keyword))
               (kwargs (cddr field))
               (pw (getf kwargs :present-when)))
          (when pw
            (let* ((cond-field (first pw))
                   (cond-value (second pw))
                   (actual (getf instance cond-field)))
              (if (eq actual cond-value)
                  (when (null (getf instance key))
                    (push (format nil "~A:~A (present-when ~A=~A but field is nil)"
                                  entity-name fname cond-field cond-value)
                          violations))
                  (when (not (null (getf instance key)))
                    (push (format nil "~A:~A (absent-when ~A/=~A but field is non-nil)"
                                  entity-name fname cond-field cond-value)
                          violations))))))))
    ;; Variant-specific invariants
    (dolist (vkey (entity-variants entity-name))
      (let* ((variant (describe-variant vkey))
             (disc (getf variant :discriminator))
             (val (getf variant :value))
             (actual (getf instance disc)))
        (when (eq actual val)
          (dolist (entry (variant-invariants-for vkey))
            (destructuring-bind (inv-name inv) entry
              (let ((on-sym (getf inv :on))
                    (check-form (getf inv :check)))
                (handler-case
                    (let ((fn (get-compiled-fn inv-name (list on-sym) check-form)))
                      (unless (funcall fn instance)
                        (push inv-name violations)))
                  (error (e)
                    (push (format nil "~A (error: ~A)" inv-name e) violations)))))))))
    (if violations
        (cons :fail (nreverse violations))
        '(:pass))))

(defun scenario-invariants-for (scenario-name)
  "Return a list of (inv-name inv-plist) for invariants whose :on matches SCENARIO-NAME."
  (let ((sname (string-downcase (string scenario-name))))
    (loop for inv-name in (list-invariants)
          for inv = (describe-invariant inv-name)
          when (string-equal (string-downcase (symbol-name (getf inv :on)))
                             sname)
            collect (list inv-name inv))))

(defun check-scenario-invariants (scenario-name scenario-instance)
  "Check all scenario-level invariants for SCENARIO-NAME against SCENARIO-INSTANCE.
SCENARIO-INSTANCE is a plist mapping binding keywords to instances (or lists of instances).
Invariant check forms receive bindings as variables via flat-binding:
singular bindings (cardinality 1) are single plists, plural bindings are lists.
Returns (:PASS) when all invariants hold, or (:FAIL inv1 inv2 ...) with violation names."
  (let ((scenario (describe-scenario scenario-name))
        (violations nil))
    (when scenario
      (let* ((bindings (getf scenario :entities))
             ;; Build (sym value) pairs for let-binding
             (bind-pairs
               (mapcar (lambda (espec)
                         (let* ((binding-kw (getf espec :binding))
                                (sym (intern (symbol-name binding-kw)))
                                (val (getf scenario-instance binding-kw)))
                           (list sym val)))
                       bindings)))
        (dolist (entry (scenario-invariants-for scenario-name))
          (destructuring-bind (inv-name inv) entry
            (let ((check-form (getf inv :check)))
              (handler-case
                  (let* ((params (mapcar #'first bind-pairs))
                         (fn (get-compiled-fn inv-name params check-form)))
                    (unless (apply fn (mapcar #'second bind-pairs))
                      (push inv-name violations)))
                (error (e)
                  (push (format nil "~A (error: ~A)" inv-name e) violations))))))))
    (if violations
        (cons :fail (nreverse violations))
        '(:pass))))

(defun config-invariants ()
  "Return a list of (inv-name inv-plist) for invariants with :on :config."
  (loop for inv-name in (list-invariants)
        for inv = (describe-invariant inv-name)
        when (and (getf inv :on)
                  (keywordp (getf inv :on))
                  (string-equal (symbol-name (getf inv :on)) "CONFIG"))
          collect (list inv-name inv)))

(defun check-config-invariants (config-plist)
  "Check all config-level invariants against CONFIG-PLIST.
Returns (:PASS) when all hold, or (:FAIL inv1 inv2 ...) with violation names."
  (let ((violations nil)
        (*current-config* config-plist))
    (dolist (entry (config-invariants))
      (destructuring-bind (inv-name inv) entry
        (let ((check-form (getf inv :check)))
          (handler-case
              (let ((fn (get-compiled-fn inv-name () check-form)))
                (unless (funcall fn)
                  (push inv-name violations)))
            (error ()
              (push inv-name violations))))))
    (if violations
        (cons :fail (nreverse violations))
        '(:pass))))

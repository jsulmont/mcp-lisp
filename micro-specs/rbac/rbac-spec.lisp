(defhelper role-permission-ids
    (role-id role-perms)
  (remove-duplicates
   (loop for rp in role-perms
         when (equal (getf rp :role-id) role-id)
         collect (getf rp :permission-id))
   :test #'equal))

(defhelper user-effective-permissions
    (user-id user-rs all-role-perms)
  (let ((role-ids
         (remove-duplicates
          (loop for ur in user-rs
                when (equal (getf ur :user-id) user-id)
                collect (getf ur :role-id))
          :test #'equal)))
    (remove-duplicates
     (loop for rid in role-ids
           append (role-permission-ids rid all-role-perms))
     :test #'equal)))

(defhelper user-can-access-p
    (user-id user-rs all-role-perms res-perms resource-id)
  (let ((user-perms (user-effective-permissions user-id user-rs all-role-perms))
        (required
         (loop for rp in res-perms
               when (equal (getf rp :resource-id) resource-id)
               collect (getf rp :permission-id))))
    (every (lambda (req) (member req user-perms :test #'equal)) required)))

(mcp-lisp/src/spec/serialization::defentity permission nil (id string :required t :unique t)
 (name string :required t :unique t))

(mcp-lisp/src/spec/serialization::defentity role nil (id string :required t :unique t)
 (name string :required t :unique t)
 (:has-many role-permissions :of role-permission :cardinality (1 10)))

(mcp-lisp/src/spec/serialization::defentity user nil (id string :required t :unique t)
 (name string :required t) (:has-many user-roles :of user-role :cardinality (1 5)))

(mcp-lisp/src/spec/serialization::defentity resource nil (id string :required t :unique t)
 (name string :required t)
 (:has-many resource-permissions :of resource-permission :cardinality (1 5)))

(mcp-lisp/src/spec/serialization::defentity role-permission nil (id string :required t :unique t)
 (role-id string :required t) (permission-id string :required t)
 (:unique-together role-id permission-id))

(mcp-lisp/src/spec/serialization::defentity user-role nil (id string :required t :unique t)
 (user-id string :required t) (role-id string :required t) (:unique-together user-id role-id))

(mcp-lisp/src/spec/serialization::defentity resource-permission nil
 (id string :required t :unique t) (resource-id string :required t)
 (permission-id string :required t) (:unique-together resource-id permission-id))

(mcp-lisp/src/spec/serialization::definvariant permission-name-non-empty :on permission :check
 (> (length (permission-name permission)) 0))

(mcp-lisp/src/spec/serialization::definvariant role-name-non-empty :on role :check
 (> (length (role-name role)) 0))

(mcp-lisp/src/spec/serialization::definvariant user-name-non-empty :on user :check
 (> (length (user-name user)) 0))

(mcp-lisp/src/spec/serialization::definvariant resource-name-non-empty :on resource :check
 (> (length (resource-name resource)) 0))

(mcp-lisp/src/spec/serialization::defscenario rbac-access :entities
 ((permissions (3 8) permission) (roles (2 4) role) (role-perms (2 12) role-permission :per roles)
  (users (2 5) user) (user-rs (1 5) user-role :per users) (resources (1 3) resource)
  (res-perms (1 5) resource-permission :per resources)))

(mcp-lisp/src/spec/serialization::definvariant unique-role-permission-sets :on rbac-access :check
 (let ((all-role-perms (apply #'append (mapcar #'cdr role-perms))))
   (all-pairs-check roles
                    (lambda (r1 r2)
                      (let ((p1
                             (sort (copy-list (role-permission-ids (getf r1 :id) all-role-perms))
                                   #'string<))
                            (p2
                             (sort (copy-list (role-permission-ids (getf r2 :id) all-role-perms))
                                   #'string<)))
                        (not (equal p1 p2)))))))

(mcp-lisp/src/spec/serialization::definvariant role-has-permissions :on rbac-access :check
 (let ((all-role-perms (apply #'append (mapcar #'cdr role-perms))))
   (every (lambda (r) (> (length (role-permission-ids (getf r :id) all-role-perms)) 0)) roles)))

(mcp-lisp/src/spec/serialization::definvariant user-has-roles :on rbac-access :check
 (let ((all-user-rs (apply #'append (mapcar #'cdr user-rs))))
   (every
    (lambda (u)
      (>
       (loop for ur in all-user-rs
             when (equal (getf ur :user-id) (getf u :id))
             count t)
       0))
    users)))

(mcp-lisp/src/spec/serialization::definvariant effective-permissions-are-union :on rbac-access
 :check
 (let ((all-role-perms (apply #'append (mapcar #'cdr role-perms)))
       (all-user-rs (apply #'append (mapcar #'cdr user-rs)))
       (all-res-perms (apply #'append (mapcar #'cdr res-perms))))
   (every
    (lambda (u)
      (let* ((uid (getf u :id)) (eff (user-effective-permissions uid all-user-rs all-role-perms)))
        (every
         (lambda (res)
           (let* ((rid (getf res :id))
                  (required
                   (remove-duplicates
                    (loop for rp in all-res-perms
                          when (equal (getf rp :resource-id) rid)
                          collect (getf rp :permission-id))
                    :test #'equal))
                  (can-access (every (lambda (req) (member req eff :test #'equal)) required))
                  (fn-result (user-can-access-p uid all-user-rs all-role-perms all-res-perms rid)))
             (eq (not (not can-access)) (not (not fn-result)))))
         resources)))
    users)))

(defscenario-generator rbac-access
    (overrides)
  (declare (ignore overrides))
  (let* ((n-perms (+ 3 (random 6)))
         (permissions
          (loop for i from 1 to n-perms
                collect (generate-instance "permission"
                                           (list :name
                                                 (format nil "~a:~a"
                                                         (nth (random 4)
                                                              '("read" "write" "delete" "admin"))
                                                         (nth (random 4)
                                                              '("orders" "inventory" "users"
                                                                "reports")))))))
         (perm-ids (mapcar (lambda (p) (getf p :id)) permissions))
         (n-roles (+ 2 (random 3)))
         (role-perm-sets
          (let ((sets nil))
            (loop while (< (length sets) n-roles)
                  do (let* ((size (+ 1 (random (length perm-ids))))
                            (shuffled
                             (let ((copy (copy-list perm-ids)))
                               (loop for i from (length copy) downto 2
                                     do (rotatef (nth (random i) copy) (nth (1- i) copy)))
                               copy))
                            (chosen (sort (subseq shuffled 0 size) #'string<)))
                       (unless (member chosen sets :test #'equal) (push chosen sets))))
            sets))
         (roles
          (loop for i from 1 to n-roles
                collect (generate-instance "role" (list :name (format nil "role-~a" i)))))
         (role-perms
          (loop for role in roles
                for pset in role-perm-sets
                collect (cons role
                              (loop for pid in pset
                                    collect (generate-instance "role-permission"
                                                               (list :role-id (getf role :id)
                                                                     :permission-id pid))))))
         (n-users (+ 2 (random 4)))
         (users
          (loop repeat n-users
                collect (generate-instance "user")))
         (all-role-ids (mapcar (lambda (r) (getf r :id)) roles))
         (user-rs
          (loop for u in users
                collect (let* ((n-assigned (+ 1 (random (length all-role-ids))))
                               (shuffled
                                (let ((copy (copy-list all-role-ids)))
                                  (loop for i from (length copy) downto 2
                                        do (rotatef (nth (random i) copy) (nth (1- i) copy)))
                                  copy))
                               (assigned (subseq shuffled 0 n-assigned)))
                          (cons u
                                (loop for rid in assigned
                                      collect (generate-instance "user-role"
                                                                 (list :user-id (getf u :id)
                                                                       :role-id rid)))))))
         (n-resources (+ 1 (random 3)))
         (resources
          (loop repeat n-resources
                collect (generate-instance "resource")))
         (res-perms
          (loop for res in resources
                collect (let* ((n-req (+ 1 (random (min 3 (length perm-ids)))))
                               (shuffled
                                (let ((copy (copy-list perm-ids)))
                                  (loop for i from (length copy) downto 2
                                        do (rotatef (nth (random i) copy) (nth (1- i) copy)))
                                  copy))
                               (required (subseq shuffled 0 n-req)))
                          (cons res
                                (loop for pid in required
                                      collect (generate-instance "resource-permission"
                                                                 (list :resource-id (getf res :id)
                                                                       :permission-id pid))))))))
    (list :permissions permissions :roles roles :role-perms role-perms :users users :user-rs
          user-rs :resources resources :res-perms res-perms)))

(defscenario-negative-generator rbac-access
    (overrides)
  (declare (ignore overrides))
  (let* ((n-perms 4)
         (permissions
          (loop for i from 1 to n-perms
                collect (generate-instance "permission" (list :name (format nil "perm-~a" i)))))
         (perm-ids (mapcar (lambda (p) (getf p :id)) permissions))
         (shared-set (list (first perm-ids) (second perm-ids)))
         (roles
          (list (generate-instance "role" (list :name "role-dup-1"))
                (generate-instance "role" (list :name "role-dup-2"))))
         (role-perms
          (loop for role in roles
                collect (cons role
                              (loop for pid in shared-set
                                    collect (generate-instance "role-permission"
                                                               (list :role-id (getf role :id)
                                                                     :permission-id pid))))))
         (users (list (generate-instance "user")))
         (user-rs
          (list
           (cons (first users)
                 (list
                  (generate-instance "user-role"
                                     (list :user-id (getf (first users) :id) :role-id
                                           (getf (first roles) :id)))))))
         (resources (list (generate-instance "resource")))
         (res-perms
          (list
           (cons (first resources)
                 (list
                  (generate-instance "resource-permission"
                                     (list :resource-id (getf (first resources) :id) :permission-id
                                           (first perm-ids))))))))
    (list :permissions permissions :roles roles :role-perms role-perms :users users :user-rs
          user-rs :resources resources :res-perms res-perms)))


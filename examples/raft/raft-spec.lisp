(defentity server
    nil
  (id string :required t :unique t)
  (current-term number :required t)
  (state (member :follower :candidate :leader) :required t :default :follower)
  (voted-for string)
  (commit-index number :required t :default 0)
  (log-length number :required t :default 0)
  (:has-many log-entries :of log-entry))

(defentity log-entry
    nil
  (id string :required t :unique t)
  (server-id string :required t)
  (idx number :required t)
  (term number :required t)
  (value string :required t)
  (:belongs-to server :via server-id))

(defrule timeout-from-follower :when (server :state :follower) :sets
         ((server-voted-for server) nil) :ensures ((eq (server-state server) :candidate)))

(defrule timeout-from-candidate :when (server :state :candidate) :sets
         ((server-voted-for server) nil) :ensures ((eq (server-state server) :candidate)))

(defrule become-leader :when (server :state :candidate) :ensures
         ((eq (server-state server) :leader)))

(defrule step-down-from-leader :when (server :state :leader) :sets ((server-voted-for server) nil)
         :ensures ((eq (server-state server) :follower)))

(defrule step-down-from-candidate :when (server :state :candidate) :sets
         ((server-voted-for server) nil) :ensures ((eq (server-state server) :follower)))

(defrule restart-from-leader :when (server :state :leader) :sets
         ((server-commit-index server) 0 (server-voted-for server) nil) :ensures
         ((eq (server-state server) :follower)))

(defrule restart-from-candidate :when (server :state :candidate) :sets
         ((server-commit-index server) 0 (server-voted-for server) nil) :ensures
         ((eq (server-state server) :follower)))

(defrule restart-from-follower :when (server :state :follower) :sets
         ((server-commit-index server) 0 (server-voted-for server) nil) :ensures
         ((eq (server-state server) :follower)))

(definvariant term-positive :on server :check (>= (server-current-term server) 1))

(definvariant commit-index-non-negative :on server :check (>= (server-commit-index server) 0))

(definvariant commit-within-log :on server :check
              (<= (server-commit-index server) (server-log-length server)))

(definvariant log-length-non-negative :on server :check (>= (server-log-length server) 0))

(definvariant entry-index-positive :on log-entry :check (>= (log-entry-idx log-entry) 1))

(definvariant entry-term-positive :on log-entry :check (>= (log-entry-term log-entry) 1))

(defscenario raft-cluster :entities ((servers (3 5) server) (entries (0 50) log-entry)))

(definvariant election-safety :on raft-cluster :check
              (let ((leaders (remove-if-not (lambda (s) (eq (getf s :state) :leader)) servers)))
                (= (length leaders)
                   (length
                    (remove-duplicates (mapcar (lambda (s) (getf s :current-term)) leaders))))))

(definvariant log-matching :on raft-cluster :check
              (every
               (lambda (e1)
                 (every
                  (lambda (e2)
                    (or (not (= (getf e1 :idx) (getf e2 :idx)))
                        (not (= (getf e1 :term) (getf e2 :term)))
                        (string= (getf e1 :server-id) (getf e2 :server-id))
                        (string= (getf e1 :value) (getf e2 :value))))
                  entries))
               entries))

(definvariant log-indices-unique-per-server :on raft-cluster :check
              (every
               (lambda (s)
                 (let* ((server-entries
                         (remove-if-not (lambda (e) (string= (getf e :server-id) (getf s :id)))
                                        entries))
                        (indices (mapcar (lambda (e) (getf e :idx)) server-entries)))
                   (= (length indices) (length (remove-duplicates indices)))))
               servers))

(definvariant log-indices-contiguous :on raft-cluster :check
              (every
               (lambda (s)
                 (let* ((server-entries
                         (remove-if-not (lambda (e) (string= (getf e :server-id) (getf s :id)))
                                        entries))
                        (n (length server-entries))
                        (indices (sort (mapcar (lambda (e) (getf e :idx)) server-entries) #'<)))
                   (or (= n 0) (and (= (first indices) 1) (= (car (last indices)) n)))))
               servers))

(definvariant log-term-monotonicity :on raft-cluster :check
              (every
               (lambda (s)
                 (let* ((server-entries
                         (sort
                          (remove-if-not (lambda (e) (string= (getf e :server-id) (getf s :id)))
                                         entries)
                          #'< :key (lambda (e) (getf e :idx)))))
                   (or (< (length server-entries) 2)
                       (every
                        (lambda (pair) (<= (getf (first pair) :term) (getf (second pair) :term)))
                        (mapcar #'list server-entries (rest server-entries))))))
               servers))

(definvariant entry-term-bounded :on raft-cluster :check
              (every
               (lambda (s)
                 (every
                  (lambda (e)
                    (or (not (string= (getf e :server-id) (getf s :id)))
                        (<= (getf e :term) (getf s :current-term))))
                  entries))
               servers))

(definvariant log-length-consistent :on raft-cluster :check
              (every
               (lambda (s)
                 (= (getf s :log-length)
                    (length
                     (remove-if-not (lambda (e) (string= (getf e :server-id) (getf s :id)))
                                    entries))))
               servers))

(definvariant committed-prefix-agreement :on raft-cluster :check
              (let ((committed-servers
                     (remove-if (lambda (s) (= (getf s :commit-index) 0)) servers)))
                (every
                 (lambda (s1)
                   (every
                    (lambda (s2)
                      (let ((ci (min (getf s1 :commit-index) (getf s2 :commit-index))))
                        (loop for i from 1 to ci
                              for e1 = (find-if
                                        (lambda (e)
                                          (and (string= (getf e :server-id) (getf s1 :id))
                                               (= (getf e :idx) i)))
                                        entries)
                              for e2 = (find-if
                                        (lambda (e)
                                          (and (string= (getf e :server-id) (getf s2 :id))
                                               (= (getf e :idx) i)))
                                        entries)
                              always (or (null e1) (null e2)
                                         (and (= (getf e1 :term) (getf e2 :term))
                                              (string= (getf e1 :value) (getf e2 :value)))))))
                    committed-servers))
                 committed-servers)))

(defscenario-generator raft-cluster
    (overrides)
  (declare (ignore overrides))
  (let* ((num-servers (+ 3 (random 3)))
         (max-term (+ 2 (random 9)))
         (leader-terms nil)
         (committed-len (random 6))
         (committed-terms
          (sort
           (loop repeat committed-len
                 collect (+ 1 (random max-term)))
           #'<))
         (committed-values
          (loop repeat committed-len
                collect (generate-value 'string)))
         (canonical (make-hash-table :test #'equal))
         (servers nil)
         (all-entries nil))
    (loop for idx from 1 to committed-len
          for ct in committed-terms
          for cv in committed-values
          do (setf (gethash (cons idx ct) canonical) cv))
    (loop for i from 1 to num-servers
          for server-term = (+ max-term (random 3))
          for raw-state = (nth (random 3) '(:follower :candidate :leader))
          for state = (let ((s
                             (if (and (eq raw-state :leader) (member server-term leader-terms))
                                 :follower
                                 raw-state)))
                        (when (eq s :leader) (push server-term leader-terms))
                        s)
          for extra-len = (random 4)
          for total-len = (+ committed-len extra-len)
          for commit-idx = (if (= committed-len 0)
                               0
                               (random (1+ committed-len)))
          for s = (generate-instance "server"
                                     (list :current-term server-term :state state :commit-index
                                           commit-idx :log-length total-len))
          for s-id = (getf s :id)
          do (push s servers) (loop for idx from 1 to committed-len
                                    for ct in committed-terms
                                    for cv in committed-values
                                    do (push
                                        (generate-instance "log-entry"
                                                           (list :server-id s-id :idx idx :term ct
                                                                 :value cv))
                                        all-entries)) (let* ((base-term
                                                              (or (car (last committed-terms)) 1))
                                                             (extra-terms
                                                              (sort
                                                               (loop repeat extra-len
                                                                     collect (+ base-term
                                                                                (random
                                                                                 (max 1
                                                                                      (-
                                                                                       server-term
                                                                                       base-term
                                                                                       -1)))))
                                                               #'<)))
                                                        (loop for idx from (1+
                                                                            committed-len) to total-len
                                                              for et in extra-terms
                                                              for capped = (min et server-term)
                                                              for key = (cons idx capped)
                                                              for existing = (gethash key
                                                                                      canonical)
                                                              for val = (or existing
                                                                            (generate-value
                                                                             'string))
                                                              do (unless existing
                                                                   (setf (gethash key canonical)
                                                                           val)) (push
                                                                                  (generate-instance
                                                                                   "log-entry"
                                                                                   (list :server-id
                                                                                         s-id :idx
                                                                                         idx :term
                                                                                         capped
                                                                                         :value
                                                                                         val))
                                                                                  all-entries))))
    (list :servers (nreverse servers) :entries (nreverse all-entries))))

(defscenario-negative-generator raft-cluster
    (overrides)
  (declare (ignore overrides))
  (let ((violation (random 7)))
    (case violation
      (0
       (let* ((term (+ 1 (random 5)))
              (servers
               (list
                (generate-instance "server"
                                   (list :state :leader :current-term term :log-length 0
                                         :commit-index 0))
                (generate-instance "server"
                                   (list :state :leader :current-term term :log-length 0
                                         :commit-index 0))
                (generate-instance "server"
                                   (list :state :follower :current-term term :log-length 0
                                         :commit-index 0)))))
         (list :servers servers :entries nil)))
      (1
       (let* ((servers
               (list
                (generate-instance "server"
                                   (list :current-term 3 :state :follower :log-length 1
                                         :commit-index 0))
                (generate-instance "server"
                                   (list :current-term 3 :state :follower :log-length 1
                                         :commit-index 0))))
              (entries
               (list
                (generate-instance "log-entry"
                                   (list :server-id (getf (first servers) :id) :idx 1 :term 1
                                         :value "cmd-alpha"))
                (generate-instance "log-entry"
                                   (list :server-id (getf (second servers) :id) :idx 1 :term 1
                                         :value "cmd-beta")))))
         (list :servers servers :entries entries)))
      (2
       (let* ((s
               (generate-instance "server"
                                  (list :current-term 5 :state :follower :log-length 2
                                        :commit-index 0)))
              (entries
               (list (generate-instance "log-entry" (list :server-id (getf s :id) :idx 1 :term 1))
                     (generate-instance "log-entry"
                                        (list :server-id (getf s :id) :idx 5 :term 3)))))
         (list :servers (list s) :entries entries)))
      (3
       (let* ((s
               (generate-instance "server"
                                  (list :current-term 2 :state :follower :log-length 1
                                        :commit-index 0)))
              (entries
               (list
                (generate-instance "log-entry" (list :server-id (getf s :id) :idx 1 :term 7)))))
         (list :servers (list s) :entries entries)))
      (4
       (let* ((s
               (generate-instance "server"
                                  (list :current-term 3 :state :follower :log-length 5
                                        :commit-index 0)))
              (entries
               (list
                (generate-instance "log-entry" (list :server-id (getf s :id) :idx 1 :term 1)))))
         (list :servers (list s) :entries entries)))
      (5
       (let* ((s
               (generate-instance "server"
                                  (list :current-term 5 :state :follower :log-length 3
                                        :commit-index 0)))
              (entries
               (list (generate-instance "log-entry" (list :server-id (getf s :id) :idx 1 :term 3))
                     (generate-instance "log-entry" (list :server-id (getf s :id) :idx 2 :term 1))
                     (generate-instance "log-entry"
                                        (list :server-id (getf s :id) :idx 3 :term 4)))))
         (list :servers (list s) :entries entries)))
      (6
       (let* ((servers
               (list
                (generate-instance "server"
                                   (list :current-term 5 :state :follower :log-length 2
                                         :commit-index 2))
                (generate-instance "server"
                                   (list :current-term 5 :state :follower :log-length 2
                                         :commit-index 2))))
              (entries
               (list
                (generate-instance "log-entry"
                                   (list :server-id (getf (first servers) :id) :idx 1 :term 1
                                         :value "same"))
                (generate-instance "log-entry"
                                   (list :server-id (getf (second servers) :id) :idx 1 :term 1
                                         :value "same"))
                (generate-instance "log-entry"
                                   (list :server-id (getf (first servers) :id) :idx 2 :term 2
                                         :value "x"))
                (generate-instance "log-entry"
                                   (list :server-id (getf (second servers) :id) :idx 2 :term 3
                                         :value "y")))))
         (list :servers servers :entries entries))))))


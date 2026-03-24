(defentity server
    nil
  (id string :required t :unique t)
  (current-term integer :required t)
  (state (member :follower :candidate :leader) :default :follower)
  (voted-for string)
  (commit-index integer :default 0)
  (log-length integer :default 0)
  (last-log-term integer :default 0)
  (votes-responded-count integer :default 0)
  (votes-granted-count integer :default 0)
  (:has-many log-entries :of log-entry)
  (:has-many replication-states :of replication-state))

(defentity log-entry
    nil
  (id string :required t :unique t)
  (server-id string :required t)
  (index integer :required t)
  (term integer :required t)
  (value string :required t)
  (:belongs-to server))

(defentity replication-state
    nil
  (id string :required t :unique t)
  (leader-id string :required t)
  (follower-id string :required t)
  (next-index integer :required t)
  (match-index integer :default 0)
  (:belongs-to leader :of server)
  (:belongs-to follower :of server))

(defentity message
    nil
  (id string :required t :unique t)
  (mtype
   (member :request-vote-request :request-vote-response :append-entries-request
           :append-entries-response)
   :required t)
  (mterm integer :required t)
  (msource string :required t)
  (mdest string :required t)
  (status (member :pending :delivered :dropped) :default :pending))

(defconfig
  (cluster-size integer :default 3 :min 1 :max 9))

(defvariant request-vote-req
    (message :mtype :request-vote-request)
  (mlast-log-term integer :required t)
  (mlast-log-index integer :required t))

(defvariant request-vote-resp
    (message :mtype :request-vote-response)
  (mvote-granted boolean :required t))

(defvariant append-entries-req
    (message :mtype :append-entries-request)
  (mprev-log-index integer :required t)
  (mprev-log-term integer :required t)
  (mentries-count integer :required t)
  (mcommit-index integer :required t))

(defvariant append-entries-resp
    (message :mtype :append-entries-response)
  (msuccess boolean :required t)
  (mmatch-index integer :required t))

(defrule restart :when (server :state (member :follower :candidate :leader)) :sets
         ((server-commit-index server) 0 (server-votes-responded-count server) 0
          (server-votes-granted-count server) 0)
         :ensures ((eq (server-state server) :follower)))

(defrule timeout :when (server :state (member :follower :candidate)) :sets
         ((server-current-term server) (+ (server-current-term server) 1) (server-voted-for server)
          nil (server-votes-responded-count server) 0 (server-votes-granted-count server) 0)
         :ensures ((eq (server-state server) :candidate)))

(defrule request-vote :when (server :state :candidate) :ensures
         ((eq (server-state server) :candidate)))

(defrule become-leader :when (server :state :candidate) :requires
         ((> (* 2 (server-votes-granted-count server)) (config :cluster-size))) :ensures
         ((eq (server-state server) :leader)))

(defrule client-request :when (server :state :leader) :sets
         ((server-log-length server) (+ (server-log-length server) 1) (server-last-log-term server)
          (server-current-term server))
         :ensures ((eq (server-state server) :leader)))

(defrule advance-commit-index :when (server :state :leader) :requires
         ((< (server-commit-index server) (server-log-length server))) :sets
         ((server-commit-index server) (+ (server-commit-index server) 1)) :ensures
         ((eq (server-state server) :leader)))

(defrule append-entries-send :when (server :state :leader) :ensures
         ((eq (server-state server) :leader)))

(defrule update-term :when (server :state (member :follower :candidate :leader)) :sets
         ((server-current-term server) (+ (server-current-term server) 1) (server-voted-for server)
          nil)
         :ensures ((eq (server-state server) :follower)))

(defrule handle-request-vote-request :when (server :state (member :follower :candidate :leader)))

(defrule handle-request-vote-response :when (server :state (member :follower :candidate :leader))
         :requires ((< (server-votes-responded-count server) (config :cluster-size))) :sets
         ((server-votes-responded-count server) (+ (server-votes-responded-count server) 1)
          (server-votes-granted-count server) (+ (server-votes-granted-count server) 1)))

(defrule reject-append-entries :when (server :state :follower) :ensures
         ((eq (server-state server) :follower)))

(defrule append-entries-step-down :when (server :state :candidate) :ensures
         ((eq (server-state server) :follower)))

(defrule accept-append-entries :when (server :state :follower) :sets
         ((server-log-length server) (+ (server-log-length server) 1) (server-last-log-term server)
          (server-current-term server) (server-commit-index server)
          (min (+ (server-commit-index server) 1) (+ (server-log-length server) 1)))
         :ensures ((eq (server-state server) :follower)))

(defrule handle-append-entries-response :when (server :state :leader) :ensures
         ((eq (server-state server) :leader)))

(defrule drop-stale-response :when (server :state (member :follower :candidate :leader)))

(defrule duplicate-message :when (message :status :pending) :ensures
         ((eq (message-status message) :pending)))

(defrule drop-message :when (message :status :pending) :ensures
         ((eq (message-status message) :dropped)))

(defrule deliver-message :when (message :status :pending) :ensures
         ((eq (message-status message) :delivered)))

(definvariant term-positive :on server :check (>= (server-current-term server) 1))

(definvariant commit-index-non-negative :on server :check (>= (server-commit-index server) 0))

(definvariant commit-within-log :on server :check
              (<= (server-commit-index server) (server-log-length server)))

(definvariant log-length-non-negative :on server :check (>= (server-log-length server) 0))

(definvariant last-log-term-non-negative :on server :check (>= (server-last-log-term server) 0))

(definvariant last-log-term-bounded :on server :check
              (<= (server-last-log-term server) (server-current-term server)))

(definvariant votes-granted-within-responded :on server :check
              (<= (server-votes-granted-count server) (server-votes-responded-count server)))

(definvariant votes-granted-bounded :on server :check
              (<= (server-votes-granted-count server) (config :cluster-size)))

(definvariant votes-responded-bounded :on server :check
              (<= (server-votes-responded-count server) (config :cluster-size)))

(definvariant empty-log-zero-last-term :on server :check
              (if (= (server-log-length server) 0)
                  (= (server-last-log-term server) 0)
                  t))

(definvariant leader-has-quorum :on server :check
              (if (eq (server-state server) :leader)
                  (> (* 2 (server-votes-granted-count server)) (config :cluster-size))
                  t))

(definvariant candidate-zero-or-collecting :on server :check
              (if (eq (server-state server) :follower)
                  (<= (server-votes-granted-count server) (server-votes-responded-count server))
                  t))

(definvariant log-entry-index-positive :on log-entry :check (>= (log-entry-index log-entry) 1))

(definvariant log-entry-term-positive :on log-entry :check (>= (log-entry-term log-entry) 1))

(definvariant next-index-positive :on replication-state :check
              (>= (replication-state-next-index replication-state) 1))

(definvariant match-index-non-negative :on replication-state :check
              (>= (replication-state-match-index replication-state) 0))

(definvariant match-below-next :on replication-state :check
              (< (replication-state-match-index replication-state)
                 (replication-state-next-index replication-state)))

(definvariant leader-follower-distinct :on replication-state :check
              (not
               (string= (replication-state-leader-id replication-state)
                        (replication-state-follower-id replication-state))))

(definvariant message-term-positive :on message :check (>= (message-mterm message) 1))

(definvariant request-vote-req-log-index-non-negative :on request-vote-req :check
              (>= (request-vote-req-mlast-log-index request-vote-req) 0))

(definvariant request-vote-req-log-term-non-negative :on request-vote-req :check
              (>= (request-vote-req-mlast-log-term request-vote-req) 0))

(definvariant append-entries-req-prev-index-non-negative :on append-entries-req :check
              (>= (append-entries-req-mprev-log-index append-entries-req) 0))

(definvariant append-entries-req-prev-term-non-negative :on append-entries-req :check
              (>= (append-entries-req-mprev-log-term append-entries-req) 0))

(definvariant append-entries-req-entries-non-negative :on append-entries-req :check
              (>= (append-entries-req-mentries-count append-entries-req) 0))

(definvariant append-entries-req-commit-non-negative :on append-entries-req :check
              (>= (append-entries-req-mcommit-index append-entries-req) 0))

(definvariant append-entries-resp-match-non-negative :on append-entries-resp :check
              (>= (append-entries-resp-mmatch-index append-entries-resp) 0))

(defscenario raft-cluster :entities
             ((servers (3 5) server) (entries (0 30) log-entry :per servers)
              (repl-states (0 10) replication-state :per servers)))

(definvariant election-safety :on raft-cluster :check
              (let ((leaders (remove-if-not (lambda (s) (eq (getf s :state) :leader)) servers)))
                (or (<= (length leaders) 1)
                    (every
                     (lambda (pair)
                       (/= (getf (first pair) :current-term) (getf (second pair) :current-term)))
                     (loop for i from 0 below (length leaders)
                           append (loop for j from (1+ i) below (length leaders)
                                        collect (list (nth i leaders) (nth j leaders))))))))

(definvariant log-matching :on raft-cluster :check
              (every
               (lambda (e1)
                 (every
                  (lambda (e2)
                    (or (not (= (getf e1 :index) (getf e2 :index)))
                        (not (= (getf e1 :term) (getf e2 :term)))
                        (string= (getf e1 :server-id) (getf e2 :server-id))
                        (string= (getf e1 :value) (getf e2 :value))))
                  entries))
               entries))

(definvariant vote-uniqueness :on raft-cluster :check
              (let ((voters (remove-if (lambda (s) (null (getf s :voted-for))) servers)))
                (every
                 (lambda (pair)
                   (or
                    (not (= (getf (first pair) :current-term) (getf (second pair) :current-term)))
                    (not (string= (getf (first pair) :id) (getf (second pair) :id)))
                    (string= (getf (first pair) :voted-for) (getf (second pair) :voted-for))))
                 (loop for i from 0 below (length voters)
                       append (loop for j from (1+ i) below (length voters)
                                    collect (list (nth i voters) (nth j voters)))))))

(definvariant commit-index-safety :on raft-cluster :check
              (every
               (lambda (s)
                 (let ((ci (getf s :commit-index)) (sid (getf s :id)))
                   (or (= ci 0)
                       (= ci
                          (count-if
                           (lambda (e)
                             (and (string= (getf e :server-id) sid) (<= (getf e :index) ci)))
                           entries)))))
               servers))

(definvariant leader-log-completeness :on raft-cluster :check
              (let ((leaders (remove-if-not (lambda (s) (eq (getf s :state) :leader)) servers)))
                (every
                 (lambda (ldr)
                   (every (lambda (s) (or (>= (getf ldr :log-length) (getf s :commit-index))))
                          servers))
                 leaders)))

(definvariant log-entry-server-exists :on raft-cluster :check
              (let ((sids (mapcar (lambda (s) (getf s :id)) servers)))
                (every (lambda (e) (member (getf e :server-id) sids :test #'string=)) entries)))

(definvariant replication-leader-exists :on raft-cluster :check
              (let ((sids (mapcar (lambda (s) (getf s :id)) servers)))
                (every (lambda (r) (member (getf r :leader-id) sids :test #'string=)) repl-states)))

(definvariant replication-follower-exists :on raft-cluster :check
              (let ((sids (mapcar (lambda (s) (getf s :id)) servers)))
                (every (lambda (r) (member (getf r :follower-id) sids :test #'string=))
                       repl-states)))

(definvariant replication-leader-is-leader :on raft-cluster :check
              (every
               (lambda (r)
                 (let ((leader
                        (find (getf r :leader-id) servers :key (lambda (s) (getf s :id)) :test
                              #'string=)))
                   (or (null leader) (eq (getf leader :state) :leader))))
               repl-states))

(defgenerator server
    (overrides)
  (let* ((state
          (or (override-val overrides :state) (nth (random 3) '(:follower :candidate :leader))))
         (cluster-sz (or (config :cluster-size) 3))
         (current-term (or (override-val overrides :current-term) (+ 1 (random 10))))
         (log-length (or (override-val overrides :log-length) (random 20)))
         (last-log-term
          (or (override-val overrides :last-log-term)
              (if (= log-length 0)
                  0
                  (+ 1 (random current-term)))))
         (commit-index (or (override-val overrides :commit-index) (random (1+ log-length))))
         (votes-responded
          (or (override-val overrides :votes-responded-count)
              (cond ((eq state :follower) 0) ((eq state :candidate) (random (1+ cluster-sz)))
                    ((eq state :leader)
                     (+ (floor cluster-sz 2) 1 (random (- cluster-sz (floor cluster-sz 2))))))))
         (votes-granted
          (or (override-val overrides :votes-granted-count)
              (cond ((eq state :follower) 0) ((eq state :candidate) (random (1+ votes-responded)))
                    ((eq state :leader)
                     (+ (floor cluster-sz 2) 1
                        (random (max 1 (- votes-responded (floor cluster-sz 2)))))))))
         (voted-for
          (or (override-val overrides :voted-for)
              (if (eq state :follower)
                  nil
                  (generate-value 'string)))))
    (list :id (or (override-val overrides :id) (generate-value 'string)) :current-term current-term
          :state state :voted-for voted-for :commit-index commit-index :log-length log-length
          :last-log-term last-log-term :votes-responded-count votes-responded :votes-granted-count
          votes-granted)))

(defgenerator replication-state
    (overrides)
  (let* ((lid (or (override-val overrides :leader-id) (generate-value 'string)))
         (fid
          (or (override-val overrides :follower-id)
              (loop for candidate = (generate-value 'string)
                    until (not (string= candidate lid))
                    finally (return candidate))))
         (next-idx (or (override-val overrides :next-index) (+ 1 (random 20))))
         (match-idx (or (override-val overrides :match-index) (random next-idx))))
    (list :id (or (override-val overrides :id) (generate-value 'string)) :leader-id lid
          :follower-id fid :next-index next-idx :match-index match-idx)))

(defgenerator message
    (overrides)
  (let* ((mtype
          (or (override-val overrides :mtype)
              (nth (random 4)
                   '(:request-vote-request :request-vote-response :append-entries-request
                     :append-entries-response))))
         (base
          (list :id (or (override-val overrides :id) (generate-value 'string)) :mtype mtype :mterm
                (or (override-val overrides :mterm) (+ 1 (random 20))) :msource
                (or (override-val overrides :msource) (generate-value 'string)) :mdest
                (or (override-val overrides :mdest) (generate-value 'string)) :status
                (or (override-val overrides :status) :pending))))
    (case mtype
      (:request-vote-request
       (append base
               (list :mlast-log-term (or (override-val overrides :mlast-log-term) (random 10))
                     :mlast-log-index (or (override-val overrides :mlast-log-index) (random 20)))))
      (:request-vote-response
       (append base
               (list :mvote-granted
                     (or (override-val overrides :mvote-granted)
                         (if (zerop (random 2))
                             t
                             nil)))))
      (:append-entries-request
       (append base
               (list :mprev-log-index (or (override-val overrides :mprev-log-index) (random 20))
                     :mprev-log-term (or (override-val overrides :mprev-log-term) (random 10))
                     :mentries-count (or (override-val overrides :mentries-count) (random 2))
                     :mcommit-index (or (override-val overrides :mcommit-index) (random 20)))))
      (:append-entries-response
       (append base
               (list :msuccess
                     (or (override-val overrides :msuccess)
                         (if (zerop (random 2))
                             t
                             nil))
                     :mmatch-index (or (override-val overrides :mmatch-index) (random 20))))))))

(defscenario-generator raft-cluster
    (overrides)
  (declare (ignore overrides))
  (let* ((cluster-sz (or (config :cluster-size) 3))
         (num-servers (+ 3 (random 3)))
         (leader-term (+ 2 (random 9)))
         (quorum (1+ (floor cluster-sz 2)))
         (server-ids
          (loop for i from 1 to num-servers
                collect (format nil "s~d" i)))
         (leader-id (nth (random num-servers) server-ids))
         (max-log-len (+ 3 (random 15)))
         (master-log
          (loop for idx from 1 to max-log-len
                for term = (+ 1 (random leader-term))
                collect (list :index idx :term term :value (format nil "cmd-~d" idx))))
         (leader-log-len max-log-len)
         (servers
          (loop for sid in server-ids
                for is-leader = (string= sid leader-id)
                for log-len = (if is-leader
                                  leader-log-len
                                  (random (1+ leader-log-len)))
                for commit-idx = (random (1+ (min log-len leader-log-len)))
                for last-term = (if (= log-len 0)
                                    0
                                    (getf (nth (1- log-len) master-log) :term))
                collect (generate-instance "server"
                                           (list :id sid :current-term leader-term :state
                                                 (if is-leader
                                                     :leader
                                                     :follower)
                                                 :voted-for
                                                 (if is-leader
                                                     leader-id
                                                     nil)
                                                 :log-length log-len :last-log-term last-term
                                                 :commit-index commit-idx :votes-responded-count
                                                 (if is-leader
                                                     quorum
                                                     0)
                                                 :votes-granted-count
                                                 (if is-leader
                                                     quorum
                                                     0)))))
         (entries
          (loop for s in servers
                for sid = (getf s :id)
                for log-len = (getf s :log-length)
                append (loop for idx from 1 to log-len
                             for master-entry = (nth (1- idx) master-log)
                             collect (generate-instance "log-entry"
                                                        (list :server-id sid :index idx :term
                                                              (getf master-entry :term) :value
                                                              (getf master-entry :value))))))
         (repl-states
          (loop for sid in server-ids
                unless (string= sid leader-id)
                collect (let* ((follower
                                (find sid servers :key (lambda (s) (getf s :id)) :test #'string=))
                               (flen (getf follower :log-length)))
                          (generate-instance "replication-state"
                                             (list :leader-id leader-id :follower-id sid
                                                   :next-index (+ 1 flen) :match-index flen))))))
    (list :servers servers :entries entries :repl-states repl-states)))

(defscenario-negative-generator raft-cluster
    (overrides)
  (declare (ignore overrides))
  (let* ((cluster-sz (or (config :cluster-size) 3))
         (violation (random 3))
         (term (+ 1 (random 10)))
         (quorum (floor (1+ cluster-sz) 2)))
    (case violation
      (0
       (let ((servers
              (list
               (generate-instance "server"
                                  (list :id "s1" :state :leader :current-term term
                                        :votes-granted-count quorum :votes-responded-count quorum))
               (generate-instance "server"
                                  (list :id "s2" :state :leader :current-term term
                                        :votes-granted-count quorum :votes-responded-count quorum))
               (generate-instance "server" (list :id "s3" :state :follower :current-term term)))))
         (list :servers servers :entries nil :repl-states nil)))
      (1
       (let* ((servers
               (list
                (generate-instance "server"
                                   (list :id "s1" :state :follower :current-term term :log-length 5
                                         :last-log-term term))
                (generate-instance "server"
                                   (list :id "s2" :state :follower :current-term term :log-length 5
                                         :last-log-term term))
                (generate-instance "server" (list :id "s3" :state :follower :current-term term))))
              (entries
               (list
                (generate-instance "log-entry"
                                   (list :server-id "s1" :index 3 :term 2 :value "cmd-a"))
                (generate-instance "log-entry"
                                   (list :server-id "s2" :index 3 :term 2 :value "cmd-b")))))
         (list :servers servers :entries entries :repl-states nil)))
      (2
       (let* ((servers
               (list
                (generate-instance "server"
                                   (list :id "s1" :state :leader :current-term term :log-length 2
                                         :last-log-term term :votes-granted-count quorum
                                         :votes-responded-count quorum))
                (generate-instance "server"
                                   (list :id "s2" :state :follower :current-term term :commit-index
                                         5 :log-length 5 :last-log-term term))
                (generate-instance "server" (list :id "s3" :state :follower :current-term term)))))
         (list :servers servers :entries nil :repl-states nil))))))


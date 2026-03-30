(defhelper majority-p
    (votes cluster-size)
  (> (length votes) (/ cluster-size 2)))

(defhelper add-to-set
    (item lst)
  (if (member item lst :test #'equal)
      lst
      (cons item lst)))

(defhelper log-up-to-date-p
    (candidate-last-term candidate-last-index voter-last-term voter-last-index)
  (or (> candidate-last-term voter-last-term)
      (and (= candidate-last-term voter-last-term) (>= candidate-last-index voter-last-index))))

(defhelper random-voter-id
    (n)
  (format nil "s~D" (+ 1 (random n))))

(defhelper at-most-one-leader-per-term
    (servers)
  (let ((leaders (remove-if-not (lambda (s) (eq (getf s :state) :leader)) servers)))
    (loop for (a . rest) on leaders
          never (loop for b in rest
                      thereis (= (getf a :current-term) (getf b :current-term))))))

(defentity server
    nil
  (id string :required t :unique t)
  (current-term integer :required t :default 1 :min 1)
  (state (member :follower :candidate :leader) :default :follower)
  (voted-for string :nullable t)
  (votes-responded (list-of string) :default nil)
  (votes-granted (list-of string) :default nil)
  (last-log-term integer :default 0 :min 0)
  (last-log-index integer :default 0 :min 0))

(defentity message
    nil
  (id string :required t :unique t)
  (mtype (member :request-vote-request :request-vote-response) :required t)
  (mterm integer :required t :min 1)
  (msource string :required t)
  (mdest string :required t)
  (mvote-granted boolean :nullable t)
  (mlast-log-term integer :default 0 :min 0)
  (mlast-log-index integer :default 0 :min 0))

(defconfig
  (cluster-size integer :default 3 :min 3 :max 5))

(defrule timeout :when (server :state (member :follower :candidate)) :sets
         ((server-state server) :candidate (server-current-term server)
          (+ (server-current-term server) 1) (server-voted-for server) nil
          (server-votes-responded server) nil (server-votes-granted server) nil))

(defrule request-vote :when (server :state :candidate) :creates
         ((message :mtype :request-vote-request :mterm (server-current-term server) :msource
           (server-id server) :mdest "broadcast" :mlast-log-term (server-last-log-term server)
           :mlast-log-index (server-last-log-index server))))

(defrule handle-request-vote-request :when (server :state (member :follower :candidate :leader))
         :requires ((null (server-voted-for server))) :sets ((server-voted-for server) "granted")
         :creates
         ((message :mtype :request-vote-response :mterm (server-current-term server) :msource
           (server-id server) :mdest "requestor" :mvote-granted t)))

(defrule handle-request-vote-response :when (server :state :candidate) :let
         ((voter-id (random-voter-id (or (config :cluster-size) 3)))) :requires
         ((not (member voter-id (server-votes-responded server) :test #'equal))) :sets
         ((server-votes-responded server) (add-to-set voter-id (server-votes-responded server))
          (server-votes-granted server) (add-to-set voter-id (server-votes-granted server))))

(defrule become-leader :when (server :state :candidate) :requires
         ((majority-p (server-votes-granted server) (or (config :cluster-size) 3))) :sets
         ((server-state server) :leader))

(defrule update-term :when (server :state (member :follower :candidate :leader)) :sets
         ((server-current-term server) (+ (server-current-term server) 1) (server-state server)
          :follower (server-voted-for server) nil))

(defrule restart :when (server :state (member :follower :candidate :leader)) :sets
         ((server-state server) :follower (server-votes-responded server) nil
          (server-votes-granted server) nil))

(defrule drop-stale-response :when (message :mtype :request-vote-response) :deletes (message))

(definvariant term-positive :on server :check (>= (server-current-term server) 1))

(definvariant leader-has-quorum :on server :check
              (or (not (eq (server-state server) :leader))
                  (majority-p (server-votes-granted server) (or (config :cluster-size) 3))))

(definvariant votes-granted-subset-responded :on server :check
              (subsetp (server-votes-granted server) (server-votes-responded server) :test #'equal))

(definvariant votes-bounded-by-cluster :on server :check
              (<= (length (server-votes-granted server)) (or (config :cluster-size) 5)))

(defscenario raft-election :entities ((servers (3 5) server) (messages (0 10) message)))

(definvariant election-safety :on raft-election :check (at-most-one-leader-per-term servers))

(defgenerator server
    (overrides)
  (let* ((inst (default-generate-instance "server" overrides))
         (state (getf inst :state))
         (n (or (config :cluster-size) 3))
         (all-ids
          (loop for i from 1 to n
                collect (format nil "s~D" i))))
    (when (eq state :candidate)
      (unless (getf overrides :votes-responded)
        (let* ((k (random (1+ n)))
               (responded (subseq (alexandria:shuffle (copy-list all-ids)) 0 k)))
          (setf (getf inst :votes-responded) responded)))
      (unless (getf overrides :votes-granted)
        (let* ((responded (getf inst :votes-responded))
               (gk (random (1+ (length responded))))
               (granted (subseq (alexandria:shuffle (copy-list responded)) 0 gk)))
          (setf (getf inst :votes-granted) granted))))
    (when (member state '(:follower :leader))
      (unless (getf overrides :votes-responded) (setf (getf inst :votes-responded) nil))
      (unless (getf overrides :votes-granted) (setf (getf inst :votes-granted) nil)))
    (setf (getf inst :last-log-term) 0)
    (setf (getf inst :last-log-index) 0)
    inst))

(defscenario-generator raft-election
    (overrides)
  (declare (ignore overrides))
  (let* ((n (or (config :cluster-size) 3))
         (servers
          (loop for i from 1 to n
                collect (generate-instance "server"
                                           (list :id (format nil "s~D" i) :state :follower
                                                 :current-term 1 :voted-for nil :votes-responded
                                                 nil :votes-granted nil)))))
    (list :servers servers :messages nil)))

(defscenario-negative-generator raft-election
    (overrides)
  (declare (ignore overrides))
  (let* ((n (or (config :cluster-size) 3))
         (term (+ 1 (random 5)))
         (all-ids
          (loop for i from 1 to n
                collect (format nil "s~D" i)))
         (servers
          (loop for i from 1 to n
                collect (generate-instance "server"
                                           (list :id (format nil "s~D" i) :state
                                                 (if (<= i 2)
                                                     :leader
                                                     :follower)
                                                 :current-term term :voted-for nil :votes-responded
                                                 all-ids :votes-granted all-ids)))))
    (list :servers servers :messages nil)))


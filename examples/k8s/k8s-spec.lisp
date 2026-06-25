;;; K8s Scheduling, Pod Lifecycle, Services & Resource Quotas — Behavioral Spec
;;; Entities: namespace, node, pod, container, deployment, replica-set,
;;;           service, service-port, endpoint-slice, endpoint,
;;;           resource-quota, limit-range
;;; Sources: kubernetes.io pod-lifecycle, deployments, node-pressure-eviction, service

(defentity namespace ()
  (id string :required t :unique t)
  (name string :required t)
  (phase (member :active :terminating) :default :active))

(defentity node ()
  (id string :required t :unique t)
  (name string :required t)
  (status (member :ready :not-ready :unknown) :default :ready)
  (memory-capacity-mi number :required t)
  (cpu-capacity-m number :required t)
  (memory-allocatable-mi number :required t)
  (cpu-allocatable-m number :required t)
  (disk-capacity-gi number :required t)
  (disk-available-gi number :required t)
  (memory-available-mi number :required t)
  (pid-available number :required t)
  (memory-pressure boolean :default nil)
  (disk-pressure boolean :default nil)
  (pid-pressure boolean :default nil)
  (unschedulable boolean :default nil)
  (:has-many pods :of pod))

(defentity pod ()
  (id string :required t :unique t)
  (name string :required t)
  (namespace-id string :required t)
  (node-id string)
  (phase (member :pending :running :succeeded :failed :unknown) :default :pending)
  (qos-class (member :guaranteed :burstable :best-effort) :default :burstable)
  (priority number :default 0)
  (restart-policy (member :always :on-failure :never) :default :always)
  (termination-grace-period-seconds number :default 30)
  (total-cpu-request-m number :default 0)
  (total-cpu-limit-m number :default 0)
  (total-memory-request-mi number :default 0)
  (total-memory-limit-mi number :default 0)
  (ready boolean :default nil)
  (scheduled boolean :default nil)
  (:has-many containers :of container))

(defentity container ()
  (id string :required t :unique t)
  (name string :required t)
  (pod-id string :required t)
  (state (member :waiting :running :terminated) :default :waiting)
  (image string :required t)
  (cpu-request-m number :default 0)
  (cpu-limit-m number :default 0)
  (memory-request-mi number :default 0)
  (memory-limit-mi number :default 0)
  (restart-count number :default 0)
  (exit-code number)
  (liveness-probe-ok boolean :default t)
  (readiness-probe-ok boolean :default t)
  (startup-probe-ok boolean :default t))

(defentity deployment ()
  (id string :required t :unique t)
  (name string :required t)
  (namespace-id string :required t)
  (replicas number :required t)
  (strategy (member :rolling-update :recreate) :default :rolling-update)
  (max-surge number :default 1)
  (max-unavailable number :default 1)
  (min-ready-seconds number :default 0)
  (progress-deadline-seconds number :default 600)
  (revision-history-limit number :default 10)
  (condition (member :progressing :complete :failed) :default :progressing)
  (paused boolean :default nil)
  (:has-many replica-sets :of replica-set))

(defentity replica-set ()
  (id string :required t :unique t)
  (name string :required t)
  (namespace-id string :required t)
  (deployment-id string :required t)
  (revision number :required t)
  (desired-replicas number :required t)
  (current-replicas number :required t)
  (ready-replicas number :default 0)
  (available-replicas number :default 0)
  (pod-template-hash string :required t)
  (:has-many pods :of pod))

;;; Service networking entities

(defentity service ()
  (id string :required t :unique t)
  (name string :required t)
  (namespace-id string :required t)
  (type (member :cluster-ip :node-port :load-balancer :external-name) :default :cluster-ip)
  (cluster-ip string)
  (external-name string)
  (session-affinity (member :none :client-ip) :default :none)
  (session-affinity-timeout-seconds number :default 10800)
  (external-traffic-policy (member :cluster :local) :default :cluster)
  (internal-traffic-policy (member :cluster :local) :default :cluster)
  (headless boolean :default nil)
  (has-selector boolean :default t)
  (publish-not-ready-addresses boolean :default nil)
  (:has-many service-ports :of service-port)
  (:has-many endpoint-slices :of endpoint-slice))

(defentity service-port ()
  (id string :required t :unique t)
  (service-id string :required t)
  (name string)
  (protocol (member :tcp :udp :sctp) :default :tcp)
  (port number :required t)
  (target-port number :required t)
  (node-port number)
  (app-protocol string))

(defentity endpoint-slice ()
  (id string :required t :unique t)
  (service-id string :required t)
  (address-type (member :ipv4 :ipv6 :fqdn) :default :ipv4)
  (endpoint-count number :default 0)
  (:has-many endpoints :of endpoint))

(defentity endpoint ()
  (id string :required t :unique t)
  (endpoint-slice-id string :required t)
  (address string :required t)
  (node-name string)
  (zone string)
  (ready boolean :default t)
  (serving boolean :default t)
  (terminating boolean :default nil)
  (pod-id string))

;;; Resource management entities

(defentity resource-quota ()
  (id string :required t :unique t)
  (name string :required t)
  (namespace-id string :required t)
  (hard-cpu-m number)
  (hard-memory-mi number)
  (hard-pods number)
  (hard-services number)
  (hard-secrets number)
  (hard-configmaps number)
  (hard-pvcs number)
  (used-cpu-m number :default 0)
  (used-memory-mi number :default 0)
  (used-pods number :default 0)
  (used-services number :default 0)
  (used-secrets number :default 0)
  (used-configmaps number :default 0)
  (used-pvcs number :default 0))

(defentity limit-range ()
  (id string :required t :unique t)
  (name string :required t)
  (namespace-id string :required t)
  (type (member :pod :container :pvc) :default :container)
  (default-cpu-request-m number)
  (default-cpu-limit-m number)
  (default-memory-request-mi number)
  (default-memory-limit-mi number)
  (min-cpu-m number)
  (max-cpu-m number)
  (min-memory-mi number)
  (max-memory-mi number))

;;; Config — eviction thresholds

(defconfig
  (hard-eviction-memory-mi number :default 50 :min 0 :max 1000)
  (hard-eviction-disk-pct number :default 5 :min 0 :max 50)
  (soft-eviction-memory-mi number :default 100 :min 0 :max 2000)
  (soft-eviction-disk-pct number :default 10 :min 0 :max 50)
  (eviction-pressure-transition-period-s number :default 300 :min 0 :max 3600))

;;; Invariants — per-entity

(definvariant allocatable-le-capacity
  :on node
  :check (and (<= (node-memory-allocatable-mi node) (node-memory-capacity-mi node))
              (<= (node-cpu-allocatable-m node) (node-cpu-capacity-m node))))

(definvariant pressure-matches-threshold
  :on node
  :check (and (if (node-memory-pressure node)
                  (< (node-memory-available-mi node) (config :soft-eviction-memory-mi))
                  (>= (node-memory-available-mi node) (config :soft-eviction-memory-mi)))
              (if (node-disk-pressure node)
                  (< (* (/ (node-disk-available-gi node) (node-disk-capacity-gi node)) 100)
                     (config :soft-eviction-disk-pct))
                  (>= (* (/ (node-disk-available-gi node) (node-disk-capacity-gi node)) 100)
                       (config :soft-eviction-disk-pct)))))

(definvariant container-request-le-limit
  :on container
  :check (and (if (and (> (container-cpu-request-m container) 0)
                       (> (container-cpu-limit-m container) 0))
                  (<= (container-cpu-request-m container) (container-cpu-limit-m container))
                  t)
              (if (and (> (container-memory-request-mi container) 0)
                       (> (container-memory-limit-mi container) 0))
                  (<= (container-memory-request-mi container) (container-memory-limit-mi container))
                  t)))

(definvariant restart-count-non-negative
  :on container
  :check (>= (container-restart-count container) 0))

(definvariant terminated-has-exit-code
  :on container
  :check (if (eq (container-state container) :terminated)
             (not (null (container-exit-code container)))
             t))

(definvariant deployment-surge-bounds
  :on deployment
  :check (and (>= (deployment-max-surge deployment) 0)
              (>= (deployment-max-unavailable deployment) 0)
              (> (+ (deployment-max-surge deployment)
                    (deployment-max-unavailable deployment))
                 0)))

(definvariant replica-set-ready-le-current
  :on replica-set
  :check (and (<= (replica-set-ready-replicas replica-set)
                  (replica-set-current-replicas replica-set))
              (<= (replica-set-available-replicas replica-set)
                  (replica-set-ready-replicas replica-set))))

(definvariant deployment-paused-not-progressing
  :on deployment
  :check (if (deployment-paused deployment)
             (not (eq (deployment-condition deployment) :progressing))
             t))

(definvariant succeeded-pod-not-restarting
  :on pod
  :check (if (eq (pod-phase pod) :succeeded)
             (member (pod-restart-policy pod) '(:never :on-failure))
             t))

(definvariant scheduled-pod-has-node
  :on pod
  :check (and (if (pod-scheduled pod)
                  (not (null (pod-node-id pod)))
                  t)
              (if (not (eq (pod-phase pod) :pending))
                  (pod-scheduled pod)
                  t)))

;;; Invariants — resource quota & limit range

(definvariant quota-used-le-hard-cpu
  :on resource-quota
  :check (if (not (null (resource-quota-hard-cpu-m resource-quota)))
             (<= (resource-quota-used-cpu-m resource-quota)
                 (resource-quota-hard-cpu-m resource-quota))
             t))

(definvariant quota-used-le-hard-memory
  :on resource-quota
  :check (if (not (null (resource-quota-hard-memory-mi resource-quota)))
             (<= (resource-quota-used-memory-mi resource-quota)
                 (resource-quota-hard-memory-mi resource-quota))
             t))

(definvariant quota-used-le-hard-pods
  :on resource-quota
  :check (if (not (null (resource-quota-hard-pods resource-quota)))
             (<= (resource-quota-used-pods resource-quota)
                 (resource-quota-hard-pods resource-quota))
             t))

(definvariant quota-used-le-hard-services
  :on resource-quota
  :check (if (not (null (resource-quota-hard-services resource-quota)))
             (<= (resource-quota-used-services resource-quota)
                 (resource-quota-hard-services resource-quota))
             t))

(definvariant quota-used-non-negative
  :on resource-quota
  :check (and (>= (resource-quota-used-cpu-m resource-quota) 0)
              (>= (resource-quota-used-memory-mi resource-quota) 0)
              (>= (resource-quota-used-pods resource-quota) 0)
              (>= (resource-quota-used-services resource-quota) 0)))

(definvariant quota-hard-positive
  :on resource-quota
  :check (and (or (null (resource-quota-hard-cpu-m resource-quota))
                  (> (resource-quota-hard-cpu-m resource-quota) 0))
              (or (null (resource-quota-hard-memory-mi resource-quota))
                  (> (resource-quota-hard-memory-mi resource-quota) 0))
              (or (null (resource-quota-hard-pods resource-quota))
                  (> (resource-quota-hard-pods resource-quota) 0))
              (or (null (resource-quota-hard-services resource-quota))
                  (> (resource-quota-hard-services resource-quota) 0))))

(definvariant limit-range-min-le-max
  :on limit-range
  :check (and (if (and (not (null (limit-range-min-cpu-m limit-range)))
                       (not (null (limit-range-max-cpu-m limit-range))))
                  (<= (limit-range-min-cpu-m limit-range)
                      (limit-range-max-cpu-m limit-range))
                  t)
              (if (and (not (null (limit-range-min-memory-mi limit-range)))
                       (not (null (limit-range-max-memory-mi limit-range))))
                  (<= (limit-range-min-memory-mi limit-range)
                      (limit-range-max-memory-mi limit-range))
                  t)))

(definvariant limit-range-defaults-within-bounds
  :on limit-range
  :check (and (if (and (not (null (limit-range-default-cpu-request-m limit-range)))
                       (not (null (limit-range-min-cpu-m limit-range))))
                  (>= (limit-range-default-cpu-request-m limit-range)
                      (limit-range-min-cpu-m limit-range))
                  t)
              (if (and (not (null (limit-range-default-cpu-limit-m limit-range)))
                       (not (null (limit-range-max-cpu-m limit-range))))
                  (<= (limit-range-default-cpu-limit-m limit-range)
                      (limit-range-max-cpu-m limit-range))
                  t)
              (if (and (not (null (limit-range-default-memory-request-mi limit-range)))
                       (not (null (limit-range-min-memory-mi limit-range))))
                  (>= (limit-range-default-memory-request-mi limit-range)
                      (limit-range-min-memory-mi limit-range))
                  t)
              (if (and (not (null (limit-range-default-memory-limit-mi limit-range)))
                       (not (null (limit-range-max-memory-mi limit-range))))
                  (<= (limit-range-default-memory-limit-mi limit-range)
                      (limit-range-max-memory-mi limit-range))
                  t)))

(definvariant limit-range-request-le-limit-defaults
  :on limit-range
  :check (and (if (and (not (null (limit-range-default-cpu-request-m limit-range)))
                       (not (null (limit-range-default-cpu-limit-m limit-range))))
                  (<= (limit-range-default-cpu-request-m limit-range)
                      (limit-range-default-cpu-limit-m limit-range))
                  t)
              (if (and (not (null (limit-range-default-memory-request-mi limit-range)))
                       (not (null (limit-range-default-memory-limit-mi limit-range))))
                  (<= (limit-range-default-memory-request-mi limit-range)
                      (limit-range-default-memory-limit-mi limit-range))
                  t)))

;;; Invariants — service & endpoints

(definvariant port-range-valid
  :on service-port
  :check (and (>= (service-port-port service-port) 1)
              (<= (service-port-port service-port) 65535)
              (>= (service-port-target-port service-port) 1)
              (<= (service-port-target-port service-port) 65535)))

(definvariant node-port-range-valid
  :on service-port
  :check (if (not (null (service-port-node-port service-port)))
             (and (>= (service-port-node-port service-port) 30000)
                  (<= (service-port-node-port service-port) 32767))
             t))

(definvariant session-affinity-timeout-bounds
  :on service
  :check (if (eq (service-session-affinity service) :client-ip)
             (and (>= (service-session-affinity-timeout-seconds service) 1)
                  (<= (service-session-affinity-timeout-seconds service) 86400))
             t))

(definvariant external-name-requires-type
  :on service
  :check (if (eq (service-type service) :external-name)
             (and (not (null (service-external-name service)))
                  (not (service-has-selector service)))
             t))

(definvariant headless-no-cluster-ip
  :on service
  :check (if (service-headless service)
             (null (service-cluster-ip service))
             t))

(definvariant cluster-ip-required-for-non-headless
  :on service
  :check (if (and (not (service-headless service))
                  (not (eq (service-type service) :external-name)))
             (not (null (service-cluster-ip service)))
             t))

(definvariant external-traffic-policy-requires-external-type
  :on service
  :check (if (eq (service-external-traffic-policy service) :local)
             (member (service-type service) '(:node-port :load-balancer))
             t))

(definvariant endpoint-not-ready-and-terminating
  :on endpoint
  :check (if (endpoint-terminating endpoint)
             (not (endpoint-ready endpoint))
             t))

(definvariant endpoint-serving-when-terminating
  :on endpoint
  :check (if (and (endpoint-serving endpoint) (endpoint-terminating endpoint))
             (not (endpoint-ready endpoint))
             t))

(definvariant endpoint-slice-count-bounded
  :on endpoint-slice
  :check (and (>= (endpoint-slice-endpoint-count endpoint-slice) 0)
              (<= (endpoint-slice-endpoint-count endpoint-slice) 100)))

;;; Rules — pod lifecycle

(defrule schedule-pod
  :when (pod :phase :pending)
  :requires ((not (pod-scheduled pod)))
  :ensures ((eq (pod-scheduled pod) t)
            (eq (pod-phase pod) :pending)))

(defrule start-pod
  :when (pod :phase :pending)
  :requires ((pod-scheduled pod))
  :ensures ((eq (pod-phase pod) :running)))

(defrule succeed-pod
  :when (pod :phase :running)
  :requires ((member (pod-restart-policy pod) '(:never :on-failure)))
  :ensures ((eq (pod-phase pod) :succeeded)))

(defrule fail-pod
  :when (pod :phase :running)
  :ensures ((eq (pod-phase pod) :failed)))

(defrule lose-node-contact
  :when (pod :phase :running)
  :ensures ((eq (pod-phase pod) :unknown)))

(defrule recover-pod
  :when (pod :phase :unknown)
  :ensures ((eq (pod-phase pod) :running)))

;;; Rules — deployment lifecycle

(defrule begin-rollout
  :when (deployment :condition :complete)
  :requires ((not (deployment-paused deployment)))
  :ensures ((eq (deployment-condition deployment) :progressing)))

(defrule complete-rollout
  :when (deployment :condition :progressing)
  :ensures ((eq (deployment-condition deployment) :complete)))

(defrule fail-rollout
  :when (deployment :condition :progressing)
  :ensures ((eq (deployment-condition deployment) :failed)))

(defrule pause-deployment
  :when (deployment :condition :complete)
  :requires ((not (deployment-paused deployment)))
  :ensures ((eq (deployment-paused deployment) t)))

(defrule resume-deployment
  :when (deployment :paused t)
  :requires ((deployment-paused deployment))
  :ensures ((eq (deployment-paused deployment) nil)))

;;; Scenarios — cross-entity invariants

(defscenario node-scheduling
  :entities ((nodes (1 3) node)
             (pods (5 20) pod)))

(definvariant node-cpu-not-overcommitted
  :on node-scheduling
  :check (every (lambda (n)
                  (let ((node-pods (remove-if-not
                                    (lambda (p) (equal (pod-node-id p) (node-id n)))
                                    pods)))
                    (<= (reduce #'+ node-pods :key #'pod-total-cpu-request-m :initial-value 0)
                        (node-cpu-allocatable-m n))))
                nodes))

(definvariant node-memory-not-overcommitted
  :on node-scheduling
  :check (every (lambda (n)
                  (let ((node-pods (remove-if-not
                                    (lambda (p) (equal (pod-node-id p) (node-id n)))
                                    pods)))
                    (<= (reduce #'+ node-pods :key #'pod-total-memory-request-mi :initial-value 0)
                        (node-memory-allocatable-mi n))))
                nodes))

(definvariant no-pods-on-unschedulable-node
  :on node-scheduling
  :check (every (lambda (n)
                  (if (node-unschedulable n)
                      (notany (lambda (p) (equal (pod-node-id p) (node-id n))) pods)
                      t))
                nodes))

(defscenario deployment-rollout
  :entities ((dep 1 deployment)
             (rsets (1 3) replica-set)
             (pods (1 10) pod)))

(definvariant rollout-pod-ceiling
  :on deployment-rollout
  :check (let ((total-pods (reduce #'+ rsets :key #'replica-set-current-replicas :initial-value 0)))
           (<= total-pods (+ (deployment-replicas dep) (deployment-max-surge dep)))))

(definvariant rollout-availability-floor
  :on deployment-rollout
  :check (let ((available (reduce #'+ rsets :key #'replica-set-available-replicas :initial-value 0)))
           (>= available (- (deployment-replicas dep) (deployment-max-unavailable dep)))))

(defscenario eviction-ordering
  :entities ((n 1 node)
             (pods (5 15) pod)))

(definvariant eviction-qos-ordering
  :on eviction-ordering
  :check (if (node-memory-pressure n)
             (let* ((sorted (sort (copy-list pods)
                                  (lambda (a b)
                                    (let ((qa (position (pod-qos-class a) '(:best-effort :burstable :guaranteed)))
                                          (qb (position (pod-qos-class b) '(:best-effort :burstable :guaranteed))))
                                      (or (< qa qb)
                                          (and (= qa qb) (< (pod-priority a) (pod-priority b)))))))))
               (equal sorted (sort (copy-list pods)
                                   (lambda (a b)
                                     (let ((qa (position (pod-qos-class a) '(:best-effort :burstable :guaranteed)))
                                           (qb (position (pod-qos-class b) '(:best-effort :burstable :guaranteed))))
                                       (or (< qa qb)
                                           (and (= qa qb) (< (pod-priority a) (pod-priority b)))))))))
             t))

(defscenario service-endpoints
  :entities ((svc 1 service)
             (ports (1 5) service-port)
             (slices (1 3) endpoint-slice)
             (endpoints (1 30) endpoint)
             (pods (1 30) pod)))

(definvariant endpoints-within-slice-limit
  :on service-endpoints
  :check (every (lambda (sl)
                  (let ((slice-eps (remove-if-not
                                    (lambda (ep) (equal (endpoint-endpoint-slice-id ep)
                                                        (endpoint-slice-id sl)))
                                    endpoints)))
                    (<= (length slice-eps) 100)))
                slices))

(definvariant endpoint-count-matches-actual
  :on service-endpoints
  :check (every (lambda (sl)
                  (let ((actual (length (remove-if-not
                                         (lambda (ep) (equal (endpoint-endpoint-slice-id ep)
                                                             (endpoint-slice-id sl)))
                                         endpoints))))
                    (= (endpoint-slice-endpoint-count sl) actual)))
                slices))

(definvariant endpoint-pods-are-running
  :on service-endpoints
  :check (every (lambda (ep)
                  (if (endpoint-ready ep)
                      (let ((pod (find (endpoint-pod-id ep) pods
                                       :key #'pod-id :test #'equal)))
                        (or (null pod)
                            (eq (pod-phase pod) :running)))
                      t))
                endpoints))

(definvariant service-port-refs-service
  :on service-endpoints
  :check (every (lambda (sp)
                  (equal (service-port-service-id sp) (service-id svc)))
                ports))

;;; Generators

(defun unique-id ()
  (format nil "~a~a" (generate-value 'string) (random 1000000)))

(defun override-val (key overrides default)
  (let ((pair (assoc key overrides)))
    (if pair (cdr pair) default)))

(defun distribute (total n)
  (if (<= n 0) nil
      (loop for i from 1 to n
            collect (let ((remaining (- total (reduce #'+ result :initial-value 0))))
                     (if (= i n) remaining
                         (if (> remaining 0) (random (1+ remaining)) 0)))
              into result
            finally (return result))))

(defgenerator node (overrides)
  (declare (ignore overrides))
  (let* ((mem-cap (+ 1024.0 (random 32768.0)))
         (cpu-cap (+ 500.0 (random 16000.0)))
         (disk-cap (+ 50.0 (random 500.0)))
         (mem-alloc (* mem-cap (+ 0.5 (random 0.5))))
         (cpu-alloc (* cpu-cap (+ 0.5 (random 0.5))))
         (soft-mem (or (config :soft-eviction-memory-mi) 100))
         (soft-disk (or (config :soft-eviction-disk-pct) 10))
         (mem-pressure (< (random 1.0) 0.3))
         (mem-avail (if mem-pressure
                        (* soft-mem (random 1.0))
                        (+ soft-mem (random (max 1.0 mem-alloc)))))
         (disk-pressure (< (random 1.0) 0.3))
         (disk-avail-pct (if disk-pressure
                             (* soft-disk (random 1.0))
                             (+ soft-disk (random (max 1.0 (- 100.0 soft-disk))))))
         (disk-avail (* disk-cap (/ disk-avail-pct 100.0))))
    (list :id (generate-value 'string)
          :name (generate-value 'string)
          :status (generate-value '(member :ready :not-ready :unknown))
          :memory-capacity-mi mem-cap
          :cpu-capacity-m cpu-cap
          :memory-allocatable-mi mem-alloc
          :cpu-allocatable-m cpu-alloc
          :disk-capacity-gi disk-cap
          :disk-available-gi disk-avail
          :memory-available-mi mem-avail
          :pid-available (+ 100.0 (random 32000.0))
          :memory-pressure mem-pressure
          :disk-pressure disk-pressure
          :pid-pressure (< (random 1.0) 0.1)
          :unschedulable (< (random 1.0) 0.1))))

(defgenerator container (overrides)
  (declare (ignore overrides))
  (let* ((state (generate-value '(member :waiting :running :terminated)))
         (cpu-req (random 1000.0))
         (cpu-lim (+ cpu-req (random 1000.0)))
         (mem-req (random 1024.0))
         (mem-lim (+ mem-req (random 1024.0)))
         (exit-code (if (eq state :terminated) (random 256) nil)))
    (list :id (generate-value 'string)
          :name (generate-value 'string)
          :pod-id (generate-value 'string)
          :state state
          :image (generate-value 'string)
          :cpu-request-m cpu-req
          :cpu-limit-m cpu-lim
          :memory-request-mi mem-req
          :memory-limit-mi mem-lim
          :restart-count (random 10)
          :exit-code exit-code
          :liveness-probe-ok t
          :readiness-probe-ok t
          :startup-probe-ok t)))

(defgenerator pod (overrides)
  (let* ((phase (override-val :phase overrides
                  (generate-value '(member :pending :running :succeeded :failed :unknown))))
         (restart-policy (override-val :restart-policy overrides
                           (if (eq phase :succeeded)
                               (if (< (random 1.0) 0.5) :never :on-failure)
                               (generate-value '(member :always :on-failure :never)))))
         (scheduled (override-val :scheduled overrides (not (eq phase :pending))))
         (node-id (override-val :node-id overrides
                    (if scheduled (generate-value 'string) nil))))
    (list :id (override-val :id overrides (generate-value 'string))
          :name (override-val :name overrides (generate-value 'string))
          :namespace-id (override-val :namespace-id overrides (generate-value 'string))
          :node-id node-id
          :phase phase
          :qos-class (override-val :qos-class overrides
                       (generate-value '(member :guaranteed :burstable :best-effort)))
          :priority (override-val :priority overrides (random 1000))
          :restart-policy restart-policy
          :termination-grace-period-seconds 30
          :total-cpu-request-m (override-val :total-cpu-request-m overrides (random 2000.0))
          :total-cpu-limit-m (override-val :total-cpu-limit-m overrides (random 4000.0))
          :total-memory-request-mi (override-val :total-memory-request-mi overrides (random 4096.0))
          :total-memory-limit-mi (override-val :total-memory-limit-mi overrides (random 8192.0))
          :ready (and (eq phase :running) (< (random 1.0) 0.8))
          :scheduled scheduled)))

(defgenerator deployment (overrides)
  (declare (ignore overrides))
  (let* ((paused (< (random 1.0) 0.2))
         (condition (if paused
                        (if (< (random 1.0) 0.5) :complete :failed)
                        (generate-value '(member :progressing :complete :failed))))
         (max-surge (1+ (random 5)))
         (max-unavail (1+ (random 5))))
    (list :id (generate-value 'string)
          :name (generate-value 'string)
          :namespace-id (generate-value 'string)
          :replicas (1+ (random 10))
          :strategy (generate-value '(member :rolling-update :recreate))
          :max-surge max-surge
          :max-unavailable max-unavail
          :min-ready-seconds (random 30)
          :progress-deadline-seconds (+ 60 (random 540))
          :revision-history-limit (+ 1 (random 20))
          :condition condition
          :paused paused)))

(defgenerator replica-set (overrides)
  (let* ((current (override-val :current-replicas overrides (random 10)))
         (ready (override-val :ready-replicas overrides
                              (if (> current 0) (random (1+ current)) 0)))
         (available (override-val :available-replicas overrides
                                  (if (> ready 0) (random (1+ ready)) 0))))
    (list :id (override-val :id overrides (generate-value 'string))
          :name (override-val :name overrides (generate-value 'string))
          :namespace-id (override-val :namespace-id overrides (generate-value 'string))
          :deployment-id (override-val :deployment-id overrides (generate-value 'string))
          :revision (override-val :revision overrides (1+ (random 20)))
          :desired-replicas (override-val :desired-replicas overrides (random 10))
          :current-replicas current
          :ready-replicas ready
          :available-replicas available
          :pod-template-hash (override-val :pod-template-hash overrides (generate-value 'string)))))

;;; Scenario generators

(defscenario-generator node-scheduling (overrides)
  (declare (ignore overrides))
  (let* ((node-count (+ 1 (random 3)))
         (nodes (loop repeat node-count collect (generate-instance "node")))
         (schedulable-nodes (remove-if #'node-unschedulable nodes))
         (pod-count (+ 5 (random 16)))
         (node-cpu-used (make-hash-table :test #'equal))
         (node-mem-used (make-hash-table :test #'equal))
         (pods
           (loop repeat pod-count
                 collect
                 (if (null schedulable-nodes)
                     (generate-instance "pod"
                       (list (cons :node-id nil)
                             (cons :scheduled nil)
                             (cons :phase :pending)
                             (cons :total-cpu-request-m 0.0)
                             (cons :total-memory-request-mi 0.0)))
                     (let* ((n (nth (random (length schedulable-nodes)) schedulable-nodes))
                            (nid (node-id n))
                            (cpu-remaining (- (node-cpu-allocatable-m n)
                                              (gethash nid node-cpu-used 0.0)))
                            (mem-remaining (- (node-memory-allocatable-mi n)
                                              (gethash nid node-mem-used 0.0)))
                            (cpu-req (if (> cpu-remaining 1.0)
                                         (random (min cpu-remaining 500.0))
                                         0.0))
                            (mem-req (if (> mem-remaining 1.0)
                                         (random (min mem-remaining 1024.0))
                                         0.0)))
                       (incf (gethash nid node-cpu-used 0.0) cpu-req)
                       (incf (gethash nid node-mem-used 0.0) mem-req)
                       (generate-instance "pod"
                         (list (cons :node-id nid)
                               (cons :scheduled t)
                               (cons :total-cpu-request-m cpu-req)
                               (cons :total-memory-request-mi mem-req))))))))
    (list :nodes nodes :pods pods)))

(defscenario-generator deployment-rollout (overrides)
  (declare (ignore overrides))
  (let* ((dep (generate-instance "deployment"))
         (replicas (deployment-replicas dep))
         (max-surge (deployment-max-surge dep))
         (max-unavail (deployment-max-unavailable dep))
         (rset-count (1+ (random 3)))
         (total-ceiling (+ replicas max-surge))
         (avail-floor (max 0 (- replicas max-unavail)))
         (total-avail (+ avail-floor (random (max 1 (1+ (- total-ceiling avail-floor))))))
         (extra-current (random (max 1 (1+ (- total-ceiling total-avail)))))
         (avails (distribute total-avail rset-count))
         (extras (distribute extra-current rset-count))
         (rsets
           (loop for i from 0 below rset-count
                 for my-avail = (nth i avails)
                 for my-extra = (nth i extras)
                 for current = (+ my-avail my-extra)
                 for ready = (+ my-avail (if (> my-extra 0) (random (1+ my-extra)) 0))
                 collect (generate-instance "replica-set"
                           (list (cons :deployment-id (deployment-id dep))
                                 (cons :namespace-id (deployment-namespace-id dep))
                                 (cons :revision (1+ i))
                                 (cons :desired-replicas (if (= i (1- rset-count)) replicas 0))
                                 (cons :current-replicas current)
                                 (cons :ready-replicas ready)
                                 (cons :available-replicas my-avail)))))
         (pods (loop for rs in rsets
                     append (let ((n (replica-set-current-replicas rs)))
                              (if (> n 0)
                                  (loop repeat n collect (generate-instance "pod"))
                                  nil)))))
    (list :dep dep :rsets rsets :pods pods)))

(defgenerator service (overrides)
  (let* ((type (override-val :type overrides
                 (generate-value '(member :cluster-ip :node-port :load-balancer :external-name))))
         (headless (override-val :headless overrides
                     (and (eq type :cluster-ip) (< (random 1.0) 0.2))))
         (has-selector (override-val :has-selector overrides
                         (not (eq type :external-name))))
         (cluster-ip (if (or headless (eq type :external-name))
                         nil
                         (format nil "10.0.~a.~a" (random 256) (1+ (random 254)))))
         (external-name (if (eq type :external-name)
                            (format nil "ext-~a.example.com" (generate-value 'string))
                            nil))
         (session-affinity (override-val :session-affinity overrides
                             (generate-value '(member :none :client-ip))))
         (ext-traffic (if (member type '(:node-port :load-balancer))
                          (generate-value '(member :cluster :local))
                          :cluster)))
    (list :id (override-val :id overrides (unique-id))
          :name (override-val :name overrides (generate-value 'string))
          :namespace-id (override-val :namespace-id overrides (generate-value 'string))
          :type type
          :cluster-ip cluster-ip
          :external-name external-name
          :session-affinity session-affinity
          :session-affinity-timeout-seconds (if (eq session-affinity :client-ip)
                                                (+ 1 (random 86400))
                                                10800)
          :external-traffic-policy ext-traffic
          :internal-traffic-policy (generate-value '(member :cluster :local))
          :headless headless
          :has-selector has-selector
          :publish-not-ready-addresses (< (random 1.0) 0.1))))

(defgenerator service-port (overrides)
  (let* ((svc-type (override-val :svc-type overrides :cluster-ip))
         (has-node-port (member svc-type '(:node-port :load-balancer)))
         (node-port (if has-node-port (+ 30000 (random 2768)) nil)))
    (list :id (override-val :id overrides (unique-id))
          :service-id (override-val :service-id overrides (generate-value 'string))
          :name (override-val :name overrides (generate-value 'string))
          :protocol (generate-value '(member :tcp :udp :sctp))
          :port (+ 1 (random 65535))
          :target-port (+ 1 (random 65535))
          :node-port node-port
          :app-protocol nil)))

(defgenerator endpoint-slice (overrides)
  (list :id (override-val :id overrides (unique-id))
        :service-id (override-val :service-id overrides (generate-value 'string))
        :address-type (generate-value '(member :ipv4 :ipv6 :fqdn))
        :endpoint-count (override-val :endpoint-count overrides (random 101))))

(defgenerator endpoint (overrides)
  (let* ((terminating (override-val :terminating overrides (< (random 1.0) 0.1)))
         (ready (override-val :ready overrides (not terminating)))
         (serving (override-val :serving overrides (or ready (< (random 1.0) 0.3)))))
    (list :id (override-val :id overrides (unique-id))
          :endpoint-slice-id (override-val :endpoint-slice-id overrides (generate-value 'string))
          :address (format nil "10.244.~a.~a" (random 256) (1+ (random 254)))
          :node-name (override-val :node-name overrides (generate-value 'string))
          :zone (override-val :zone overrides nil)
          :ready ready
          :serving serving
          :terminating terminating
          :pod-id (override-val :pod-id overrides (generate-value 'string)))))

(defscenario-generator service-endpoints (overrides)
  (declare (ignore overrides))
  (let* ((svc (generate-instance "service"))
         (svc-id (service-id svc))
         (port-count (1+ (random 5)))
         (ports (loop repeat port-count
                      collect (generate-instance "service-port"
                                (list (cons :service-id svc-id)
                                      (cons :svc-type (service-type svc))))))
         (pod-count (+ 1 (random 30)))
         (pods (loop repeat pod-count
                     collect (generate-instance "pod"
                               (list (cons :phase :running)
                                     (cons :scheduled t)))))
         (slice-count (1+ (random 3)))
         (pod-idx 0)
         (eps-per-slice (distribute pod-count slice-count))
         (slices-and-eps
           (loop for i from 0 below slice-count
                 for ep-count = (nth i eps-per-slice)
                 for slice = (generate-instance "endpoint-slice"
                               (list (cons :service-id svc-id)
                                     (cons :endpoint-count ep-count)))
                 for slice-id = (endpoint-slice-id slice)
                 for eps = (loop repeat ep-count
                                 for p = (nth pod-idx pods)
                                 do (incf pod-idx)
                                 collect (generate-instance "endpoint"
                                           (list (cons :endpoint-slice-id slice-id)
                                                 (cons :pod-id (pod-id p))
                                                 (cons :ready t)
                                                 (cons :terminating nil))))
                 collect (list slice eps)))
         (slices (mapcar #'first slices-and-eps))
         (endpoints (mapcan #'second slices-and-eps)))
    (list :svc svc :ports ports :slices slices :endpoints endpoints :pods pods)))

(defgenerator resource-quota (overrides)
  (let* ((hard-cpu (override-val :hard-cpu-m overrides (+ 1000.0 (random 16000.0))))
         (hard-mem (override-val :hard-memory-mi overrides (+ 1024.0 (random 32768.0))))
         (hard-pods (override-val :hard-pods overrides (+ 5 (random 100))))
         (hard-svcs (override-val :hard-services overrides (+ 1 (random 20))))
         (used-cpu (override-val :used-cpu-m overrides (random hard-cpu)))
         (used-mem (override-val :used-memory-mi overrides (random hard-mem)))
         (used-pods (override-val :used-pods overrides (random (1+ hard-pods))))
         (used-svcs (override-val :used-services overrides (random (1+ hard-svcs)))))
    (list :id (override-val :id overrides (unique-id))
          :name (override-val :name overrides (generate-value 'string))
          :namespace-id (override-val :namespace-id overrides (generate-value 'string))
          :hard-cpu-m hard-cpu
          :hard-memory-mi hard-mem
          :hard-pods hard-pods
          :hard-services hard-svcs
          :hard-secrets (+ 1 (random 50))
          :hard-configmaps (+ 1 (random 50))
          :hard-pvcs (+ 1 (random 20))
          :used-cpu-m used-cpu
          :used-memory-mi used-mem
          :used-pods used-pods
          :used-services used-svcs
          :used-secrets 0
          :used-configmaps 0
          :used-pvcs 0)))

(defgenerator limit-range (overrides)
  (let* ((min-cpu (+ 10.0 (random 200.0)))
         (max-cpu (+ min-cpu 100.0 (random 2000.0)))
         (cpu-range (- max-cpu min-cpu))
         (def-cpu-req (+ min-cpu (random (max 1.0 cpu-range))))
         (def-cpu-lim (min max-cpu (+ def-cpu-req (random (max 1.0 (- max-cpu def-cpu-req))))))
         (min-mem (+ 16.0 (random 256.0)))
         (max-mem (+ min-mem 128.0 (random 4096.0)))
         (mem-range (- max-mem min-mem))
         (def-mem-req (+ min-mem (random (max 1.0 mem-range))))
         (def-mem-lim (min max-mem (+ def-mem-req (random (max 1.0 (- max-mem def-mem-req)))))))
    (list :id (override-val :id overrides (unique-id))
          :name (override-val :name overrides (generate-value 'string))
          :namespace-id (override-val :namespace-id overrides (generate-value 'string))
          :type (override-val :type overrides (generate-value '(member :pod :container :pvc)))
          :default-cpu-request-m def-cpu-req
          :default-cpu-limit-m def-cpu-lim
          :default-memory-request-mi def-mem-req
          :default-memory-limit-mi def-mem-lim
          :min-cpu-m min-cpu
          :max-cpu-m max-cpu
          :min-memory-mi min-mem
          :max-memory-mi max-mem)))

;;; Scenario — namespace quota

(defscenario namespace-quota
  :entities ((ns 1 namespace)
             (quota 1 resource-quota)
             (lr 1 limit-range)
             (pods (3 30) pod)
             (svcs (0 10) service)))

(definvariant quota-cpu-matches-pods
  :on namespace-quota
  :check (let ((total-cpu (reduce #'+ pods :key #'pod-total-cpu-request-m :initial-value 0)))
           (and (= (resource-quota-used-cpu-m quota) total-cpu)
                (or (null (resource-quota-hard-cpu-m quota))
                    (<= total-cpu (resource-quota-hard-cpu-m quota))))))

(definvariant quota-memory-matches-pods
  :on namespace-quota
  :check (let ((total-mem (reduce #'+ pods :key #'pod-total-memory-request-mi :initial-value 0)))
           (and (= (resource-quota-used-memory-mi quota) total-mem)
                (or (null (resource-quota-hard-memory-mi quota))
                    (<= total-mem (resource-quota-hard-memory-mi quota))))))

(definvariant quota-pod-count-matches
  :on namespace-quota
  :check (and (= (resource-quota-used-pods quota) (length pods))
              (or (null (resource-quota-hard-pods quota))
                  (<= (length pods) (resource-quota-hard-pods quota)))))

(definvariant quota-service-count-matches
  :on namespace-quota
  :check (and (= (resource-quota-used-services quota) (length svcs))
              (or (null (resource-quota-hard-services quota))
                  (<= (length svcs) (resource-quota-hard-services quota)))))

(definvariant pods-within-limit-range
  :on namespace-quota
  :check (if (eq (limit-range-type lr) :container)
             (every (lambda (p)
                      (and (or (null (limit-range-min-cpu-m lr))
                               (>= (pod-total-cpu-request-m p)
                                   (limit-range-min-cpu-m lr)))
                           (or (null (limit-range-max-cpu-m lr))
                               (<= (pod-total-cpu-request-m p)
                                   (limit-range-max-cpu-m lr)))
                           (or (null (limit-range-min-memory-mi lr))
                               (>= (pod-total-memory-request-mi p)
                                   (limit-range-min-memory-mi lr)))
                           (or (null (limit-range-max-memory-mi lr))
                               (<= (pod-total-memory-request-mi p)
                                   (limit-range-max-memory-mi lr)))))
                    pods)
             t))

(definvariant all-resources-same-namespace
  :on namespace-quota
  :check (let ((ns-id (namespace-id ns)))
           (and (equal (resource-quota-namespace-id quota) ns-id)
                (equal (limit-range-namespace-id lr) ns-id)
                (every (lambda (p) (equal (pod-namespace-id p) ns-id)) pods)
                (every (lambda (s) (equal (service-namespace-id s) ns-id)) svcs))))

(defscenario-generator namespace-quota (overrides)
  (declare (ignore overrides))
  (let* ((ns (generate-instance "namespace"))
         (ns-id (namespace-id ns))
         (lr (generate-instance "limit-range"
               (list (cons :namespace-id ns-id)
                     (cons :type :container))))
         (min-cpu (or (limit-range-min-cpu-m lr) 0))
         (max-cpu (or (limit-range-max-cpu-m lr) 2000.0))
         (min-mem (or (limit-range-min-memory-mi lr) 0))
         (max-mem (or (limit-range-max-memory-mi lr) 4096.0))
         (pod-count (+ 3 (random 28)))
         (svc-count (random 11))
         (hard-pods (+ pod-count 1 (random 20)))
         (hard-svcs (+ svc-count 1 (random 10)))
         (pods (loop repeat pod-count
                     collect (let ((cpu (+ min-cpu (random (max 1.0 (- max-cpu min-cpu)))))
                                   (mem (+ min-mem (random (max 1.0 (- max-mem min-mem))))))
                               (generate-instance "pod"
                                 (list (cons :namespace-id ns-id)
                                       (cons :total-cpu-request-m cpu)
                                       (cons :total-memory-request-mi mem))))))
         (svcs (loop repeat svc-count
                     collect (generate-instance "service"
                               (list (cons :namespace-id ns-id)))))
         (total-cpu (reduce #'+ pods :key #'pod-total-cpu-request-m :initial-value 0))
         (total-mem (reduce #'+ pods :key #'pod-total-memory-request-mi :initial-value 0))
         (quota (generate-instance "resource-quota"
                  (list (cons :namespace-id ns-id)
                        (cons :hard-cpu-m (+ total-cpu 1.0 (random 5000.0)))
                        (cons :hard-memory-mi (+ total-mem 1.0 (random 10000.0)))
                        (cons :hard-pods hard-pods)
                        (cons :hard-services hard-svcs)
                        (cons :used-cpu-m total-cpu)
                        (cons :used-memory-mi total-mem)
                        (cons :used-pods pod-count)
                        (cons :used-services svc-count)))))
    (list :ns ns :quota quota :lr lr :pods pods :svcs svcs)))

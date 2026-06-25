(defentity end-device
    nil
  (id string :required t :unique t)
  (lfdi string :required t :unique t)
  (sfdi string :required t)
  (device-type (member :direct-der :aggregator) :required t)
  (pin number)
  (enabled boolean :default t)
  (registration-state (member :pending :registered :rejected :inactive :deleted) :default :pending)
  (changed-time number :required t)
  (created-time number :required t)
  (post-rate number :default 900)
  (:has-many connection-points :of connection-point)
  (:has-many mirror-usage-points :of mirror-usage-point))

(defentity connection-point
    nil
  (id string :required t :unique t)
  (nmi string)
  (connection-status (member :connected :disconnected) :default :connected)
  (:belongs-to end-device))

(defentity device-capability
    nil
  (id string :required t :unique t)
  (poll-rate number :default 900)
  (end-device-list-link boolean :default t)
  (mirror-usage-point-list-link boolean :default t)
  (time-link boolean :default t)
  (der-program-list-link boolean :default nil)
  (self-device-link boolean :default t))

(defentity mirror-usage-point
    nil
  (id string :required t :unique t)
  (mrid string :required t :unique t)
  (description string)
  (role-flags number :default 0)
  (status (member :active :inactive :expired) :default :active)
  (created-time number :required t)
  (changed-time number :required t)
  (last-update-time number)
  (timeout-seconds number :default 259200)
  (:belongs-to end-device)
  (:has-many mirror-meter-readings :of mirror-meter-reading))

(defentity mirror-meter-reading
    nil
  (id string :required t :unique t)
  (mrid string :required t)
  (description string)
  (reading-type string)
  (value number)
  (time-stamp number :required t)
  (quality (member :valid :estimated :missing :questionable) :default :valid)
  (created-time number :required t)
  (:belongs-to mirror-usage-point))

(defentity time-resource
    nil
  (id string :required t :unique t)
  (current-time number :required t)
  (quality (member :authoritative :level-3 :level-4 :level-5 :level-6 :inaccurate) :default
   :level-3)
  (local-offset number :default 0)
  (dst-offset number :default 0)
  (dst-start number :default 0)
  (dst-end number :default 0))

(defentity acl-entry
    nil
  (id string :required t :unique t)
  (target-lfdi string :required t)
  (resource-path string :required t)
  (method (member :get :post :put :delete :head) :required t)
  (auth-type (member :certificate :pin :none) :default :certificate)
  (device-type-filter (member :direct-der :aggregator :any) :default :any)
  (allowed boolean :default t))

(defrule register-device :when (end-device :registration-state :pending) :requires
         ((end-device-lfdi end-device) (end-device-sfdi end-device)) :sets
         ((end-device-changed-time end-device) (get-universal-time)) :ensures
         ((eq (end-device-registration-state end-device) :registered)))

(defrule reject-device :when (end-device :registration-state :pending) :sets
         ((end-device-changed-time end-device) (get-universal-time)) :ensures
         ((eq (end-device-registration-state end-device) :rejected)))

(defrule deactivate-device :when (end-device :registration-state :registered) :sets
         ((end-device-enabled end-device) nil (end-device-changed-time end-device)
          (get-universal-time))
         :ensures ((eq (end-device-registration-state end-device) :inactive)))

(defrule reactivate-device :when (end-device :registration-state :inactive) :sets
         ((end-device-enabled end-device) t (end-device-changed-time end-device)
          (get-universal-time))
         :ensures ((eq (end-device-registration-state end-device) :registered)))

(defrule soft-delete-device :when (end-device :registration-state :registered) :sets
         ((end-device-enabled end-device) nil (end-device-changed-time end-device)
          (get-universal-time))
         :ensures ((eq (end-device-registration-state end-device) :deleted)))

(defrule soft-delete-inactive-device :when (end-device :registration-state :inactive) :sets
         ((end-device-changed-time end-device) (get-universal-time)) :ensures
         ((eq (end-device-registration-state end-device) :deleted)))

(defrule expire-mirror-usage-point :when (mirror-usage-point :status :active) :sets
         ((mirror-usage-point-changed-time mirror-usage-point) (get-universal-time)) :ensures
         ((eq (mirror-usage-point-status mirror-usage-point) :expired)))

(defrule deactivate-mirror-usage-point :when (mirror-usage-point :status :active) :sets
         ((mirror-usage-point-changed-time mirror-usage-point) (get-universal-time)) :ensures
         ((eq (mirror-usage-point-status mirror-usage-point) :inactive)))

(defrule reactivate-mirror-usage-point :when (mirror-usage-point :status :inactive) :sets
         ((mirror-usage-point-changed-time mirror-usage-point) (get-universal-time)) :ensures
         ((eq (mirror-usage-point-status mirror-usage-point) :active)))

(definvariant lfdi-length :on end-device :check (= (length (end-device-lfdi end-device)) 40))

(definvariant sfdi-length :on end-device :check (= (length (end-device-sfdi end-device)) 5))

(definvariant created-before-changed :on end-device :check
              (<= (end-device-created-time end-device) (end-device-changed-time end-device)))

(definvariant post-rate-positive :on end-device :check (> (end-device-post-rate end-device) 0))

(definvariant disabled-when-deleted :on end-device :check
              (if (eq (end-device-registration-state end-device) :deleted)
                  (not (end-device-enabled end-device))
                  t))

(definvariant disabled-when-inactive :on end-device :check
              (if (eq (end-device-registration-state end-device) :inactive)
                  (not (end-device-enabled end-device))
                  t))

(definvariant mup-created-before-changed :on mirror-usage-point :check
              (<= (mirror-usage-point-created-time mirror-usage-point)
                  (mirror-usage-point-changed-time mirror-usage-point)))

(definvariant mup-timeout-positive :on mirror-usage-point :check
              (> (mirror-usage-point-timeout-seconds mirror-usage-point) 0))

(definvariant reading-timestamp-before-created :on mirror-meter-reading :check
              (<= (mirror-meter-reading-time-stamp mirror-meter-reading)
                  (mirror-meter-reading-created-time mirror-meter-reading)))

(definvariant time-positive :on time-resource :check
              (> (time-resource-current-time time-resource) 0))

(definvariant dst-window-valid :on time-resource :check
              (if (and (> (time-resource-dst-start time-resource) 0)
                       (> (time-resource-dst-end time-resource) 0))
                  (<= (time-resource-dst-start time-resource)
                      (time-resource-dst-end time-resource))
                  t))

(definvariant dcap-must-have-enddevice-list :on device-capability :check
              (device-capability-end-device-list-link device-capability))

(definvariant acl-target-lfdi-length :on acl-entry :check
              (= (length (acl-entry-target-lfdi acl-entry)) 40))

(definvariant poll-rate-positive :on device-capability :check
              (> (device-capability-poll-rate device-capability) 0))

(definvariant mup-role-flags-non-negative :on mirror-usage-point :check
              (>= (mirror-usage-point-role-flags mirror-usage-point) 0))

(defscenario device-registration :entities
             ((device 1 end-device) (conn-points (1 3) connection-point)
              (acl-entries (1 5) acl-entry)))

(defscenario metering-pipeline :entities
             ((device 1 end-device) (mups (1 3) mirror-usage-point)
              (readings (1 10) mirror-meter-reading :per mups)))

(definvariant acl-matches-device :on device-registration :check
              (every (lambda (acl) (string= (getf acl :target-lfdi) (getf device :lfdi)))
                     acl-entries))

(definvariant readings-within-mup-lifetime :on metering-pipeline :check
              (let ((earliest-mup (reduce #'min mups :key (lambda (m) (getf m :created-time)))))
                (every (lambda (r) (>= (getf r :time-stamp) earliest-mup)) readings)))

(definvariant conn-points-belong-to-device :on device-registration :check t)

(defgenerator end-device
    (overrides)
  (let* ((inst (default-generate-instance "end-device" overrides))
         (lfdi (or (getf overrides :lfdi) (make-lfdi)))
         (sfdi (or (getf overrides :sfdi) (make-sfdi)))
         (created (getf inst :created-time))
         (changed (getf inst :changed-time))
         (state (getf inst :registration-state)))
    (setf (getf inst :lfdi) lfdi)
    (setf (getf inst :sfdi) sfdi)
    (when (or (null created) (null changed) (> created changed))
      (let ((t1 (+ 1000000000 (abs (or created (random 700000000))))))
        (setf (getf inst :created-time) t1)
        (setf (getf inst :changed-time) (+ t1 (random 100000)))))
    (when (member state '(:deleted :inactive)) (setf (getf inst :enabled) nil))
    inst))

(defgenerator acl-entry
    (overrides)
  (let* ((inst (default-generate-instance "acl-entry" overrides)))
    (setf (getf inst :target-lfdi) (or (getf overrides :target-lfdi) (make-lfdi)))
    inst))

(defgenerator time-resource
    (overrides)
  (let* ((inst (default-generate-instance "time-resource" overrides))
         (dst-start (getf inst :dst-start))
         (dst-end (getf inst :dst-end)))
    (when (and dst-start dst-end (> dst-start 0) (> dst-end 0) (> dst-start dst-end))
      (rotatef (getf inst :dst-start) (getf inst :dst-end)))
    (when (or (null (getf inst :current-time)) (<= (getf inst :current-time) 0))
      (setf (getf inst :current-time) (+ 1000000000 (random 700000000))))
    inst))

(defgenerator device-capability
    (overrides)
  (let ((inst (default-generate-instance "device-capability" overrides)))
    (setf (getf inst :end-device-list-link) t)
    (when (or (null (getf inst :poll-rate)) (<= (getf inst :poll-rate) 0))
      (setf (getf inst :poll-rate) (+ 60 (random 840))))
    inst))

(defscenario-generator device-registration
    (overrides)
  (declare (ignore overrides))
  (let* ((lfdi (make-lfdi))
         (device (generate-instance "end-device" (list :lfdi lfdi)))
         (conn-points
          (loop repeat (+ 1 (random 3))
                collect (generate-instance "connection-point")))
         (acl-entries
          (loop repeat (+ 1 (random 5))
                collect (generate-instance "acl-entry" (list :target-lfdi lfdi)))))
    (list :device device :conn-points conn-points :acl-entries acl-entries)))

(defscenario-generator metering-pipeline
    (overrides)
  (declare (ignore overrides))
  (let* ((device (generate-instance "end-device"))
         (base-time (max 1000000000 (getf device :created-time)))
         (mups
          (loop repeat (+ 1 (random 3))
                collect (let* ((ct (+ base-time (random 1000)))
                               (mup (generate-instance "mirror-usage-point")))
                          (setf (getf mup :created-time) ct)
                          (setf (getf mup :changed-time) (+ ct (random 500)))
                          mup)))
         (readings
          (loop for mup in mups
                for mup-ct = (getf mup :created-time)
                append (loop repeat (+ 1 (random 4))
                             collect (let* ((ts (+ mup-ct (random 10000)))
                                            (r (generate-instance "mirror-meter-reading")))
                                       (setf (getf r :time-stamp) ts)
                                       (setf (getf r :created-time) (+ ts (random 100)))
                                       r)))))
    (list :device device :mups mups :readings readings)))


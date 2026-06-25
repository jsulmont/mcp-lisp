(defentity end-device
    nil
  (id string :required t :unique t)
  (lfdi string :required t :unique t)
  (sfdi string :required t)
  (device-type (member :der :aggregator) :required t)
  (enabled boolean :default t)
  (lifecycle (member :active :soft-deleted :hard-deleted) :default :active)
  (changed-time number :required t)
  (last-interaction-time number :required t)
  (soft-deletion-time number :default 0)
  (registered-via (member :in-band :out-of-band) :required t)
  (:has-many function-set-assignments :of function-set-assignment)
  (:has-many subscriptions :of subscription)
  (:belongs-to aggregator :of end-device :optional t))

(defentity registration
    nil
  (id string :required t :unique t)
  (pin string :default "")
  (date-time number :required t)
  (:belongs-to end-device :of end-device))

(defentity connection-point
    nil
  (id string :required t :unique t)
  (connection-point-id string :required t)
  (updated-time number :required t)
  (:belongs-to end-device :of end-device))

(defentity der-program
    nil
  (id string :required t :unique t)
  (mrid string :required t :unique t)
  (description string :default "")
  (primacy number :required t)
  (changed-time number :required t)
  (poll-rate number :required t)
  (:has-many der-controls :of der-control)
  (:has-many der-curves :of der-curve))

(defentity function-set-assignment
    nil
  (id string :required t :unique t)
  (mrid string :required t :unique t)
  (description string :default "")
  (changed-time number :required t)
  (program-count number :required t)
  (:belongs-to end-device :of end-device)
  (:has-many der-program-refs :of der-program-ref))

(defentity der-program-ref
    nil
  (id string :required t :unique t)
  (:belongs-to function-set-assignment :of function-set-assignment)
  (:belongs-to der-program :of der-program))

(defentity default-der-control
    nil
  (id string :required t :unique t)
  (mrid string :required t :unique t)
  (op-mod-max-lim-w number :default 0)
  (op-mod-fixed-pf number :default 0)
  (set-grad-w number :default 0)
  (set-soft-grad-w number :default 0)
  (changed-time number :required t)
  (:belongs-to der-program :of der-program))

(defentity der-control
    nil
  (id string :required t :unique t)
  (mrid string :required t :unique t)
  (description string :default "")
  (creation-time number :required t)
  (interval-start number :required t)
  (interval-duration number :required t)
  (randomize-start number :default 0)
  (randomize-duration number :default 0)
  (event-status (member :scheduled :active :cancelled :superseded :completed) :default :scheduled)
  (potentially-superseded boolean :default nil)
  (potentially-superseded-time number :default 0)
  (op-mod-max-lim-w number :default 0)
  (op-mod-connect boolean :default t)
  (op-mod-energize boolean :default t)
  (response-required boolean :default t)
  (:belongs-to der-program :of der-program))

(defentity der-curve
    nil
  (id string :required t :unique t)
  (mrid string :required t :unique t)
  (description string :default "")
  (creation-time number :required t)
  (curve-type number :required t)
  (x-multiplier number :default 0)
  (y-multiplier number :default 0)
  (y-ref-type number :required t)
  (point-count number :required t)
  (event-status (member :scheduled :active :cancelled :superseded :completed) :default :scheduled)
  (interval-start number :required t)
  (interval-duration number :required t)
  (:belongs-to der-program :of der-program))

(defentity response
    nil
  (id string :required t :unique t)
  (subject-mrid string :required t)
  (status
   (member :received :started :completed :opt-out :opt-in :cancelled :superseded :partial-opt-out
           :partial-opt-in :no-participation :acknowledged :rejected-not-applicable
           :rejected-invalid :rejected-expired)
   :required t)
  (created-date-time number :required t)
  (:belongs-to end-device :of end-device))

(defentity subscription
    nil
  (id string :required t :unique t)
  (subscribed-resource-uri string :required t)
  (notify-uri string :required t)
  (lifecycle (member :active :expired :terminated) :default :active)
  (last-renewal-time number :required t)
  (created-time number :required t)
  (last-notification-time number :default 0)
  (:belongs-to end-device :of end-device))

(defentity mirror-usage-point
    nil
  (id string :required t :unique t)
  (mrid string :required t :unique t)
  (service-category number :default 0)
  (created-time number :required t)
  (last-post-time number :required t)
  (reading-count number :default 0)
  (:belongs-to end-device :of end-device))

(defentity log-event
    nil
  (id string :required t :unique t)
  (mrid string :required t :unique t)
  (created-time number :required t)
  (function-set number :required t)
  (log-event-code number :required t)
  (log-event-id number :required t)
  (profile-id number :default 0)
  (:belongs-to end-device :of end-device))

(defconfig
  (inactivity-threshold-days number :default 30 :min 1 :max 365)
  (soft-delete-notification-hours number :default 24 :min 1 :max 168)
  (auto-soft-delete-enabled boolean :default nil)
  (auto-assign-default-dpdgroup boolean :default nil)
  (inband-registration-direct boolean :default t)
  (inband-registration-aggregator boolean :default t)
  (pen-validation-enabled boolean :default nil)
  (nmi-checksum-validation boolean :default nil)
  (subscription-max-per-client number :default 10 :min 1 :max 100)
  (subscription-expiry-hours number :default 36 :min 1 :max 168)
  (notification-rate-limit-seconds number :default 30 :min 1 :max 300)
  (max-groups-per-device number :default 15 :min 1 :max 15)
  (default-poll-rate-seconds number :default 300 :min 60 :max 86400)
  (event-retention-margin-hours number :default 24 :min 1 :max 168)
  (max-list-limit number :default 250 :min 1 :max 10000))

(defrule soft-delete-device :when (end-device :lifecycle :active) :requires
         ((> (end-device-last-interaction-time end-device) 0)) :sets
         ((end-device-enabled end-device) nil (end-device-soft-deletion-time end-device)
          (end-device-changed-time end-device) (end-device-changed-time end-device)
          (+ (end-device-changed-time end-device) 1))
         :ensures ((eq (end-device-lifecycle end-device) :soft-deleted)))

(defrule hard-delete-device :when (end-device :lifecycle :soft-deleted) :requires
         ((> (end-device-soft-deletion-time end-device) 0)) :ensures
         ((eq (end-device-lifecycle end-device) :hard-deleted)))

(defrule reactivate-device :when (end-device :lifecycle :soft-deleted) :sets
         ((end-device-enabled end-device) t (end-device-soft-deletion-time end-device) 0
          (end-device-changed-time end-device) (+ (end-device-changed-time end-device) 1))
         :ensures ((eq (end-device-lifecycle end-device) :active)))

(defrule activate-control :when (der-control :event-status :scheduled) :requires
         ((> (der-control-interval-start der-control) 0)) :ensures
         ((eq (der-control-event-status der-control) :active)))

(defrule complete-control :when (der-control :event-status :active) :ensures
         ((eq (der-control-event-status der-control) :completed)))

(defrule cancel-control :when (der-control :event-status :scheduled) :ensures
         ((eq (der-control-event-status der-control) :cancelled)))

(defrule cancel-active-control :when (der-control :event-status :active) :ensures
         ((eq (der-control-event-status der-control) :cancelled)))

(defrule supersede-control :when (der-control :event-status :scheduled) :sets
         ((der-control-potentially-superseded der-control) t
          (der-control-potentially-superseded-time der-control)
          (der-control-creation-time der-control))
         :ensures ((eq (der-control-event-status der-control) :superseded)))

(defrule supersede-active-control :when (der-control :event-status :active) :sets
         ((der-control-potentially-superseded der-control) t
          (der-control-potentially-superseded-time der-control)
          (der-control-creation-time der-control))
         :ensures ((eq (der-control-event-status der-control) :superseded)))

(defrule activate-curve :when (der-curve :event-status :scheduled) :requires
         ((> (der-curve-interval-start der-curve) 0)) :ensures
         ((eq (der-curve-event-status der-curve) :active)))

(defrule complete-curve :when (der-curve :event-status :active) :ensures
         ((eq (der-curve-event-status der-curve) :completed)))

(defrule cancel-curve :when (der-curve :event-status :scheduled) :ensures
         ((eq (der-curve-event-status der-curve) :cancelled)))

(defrule supersede-curve :when (der-curve :event-status :active) :ensures
         ((eq (der-curve-event-status der-curve) :superseded)))

(defrule expire-subscription :when (subscription :lifecycle :active) :ensures
         ((eq (subscription-lifecycle subscription) :expired)))

(defrule terminate-subscription :when (subscription :lifecycle :active) :ensures
         ((eq (subscription-lifecycle subscription) :terminated)))

(definvariant lfdi-length :on end-device :check (= (length (end-device-lfdi end-device)) 40))

(definvariant sfdi-length :on end-device :check (= (length (end-device-sfdi end-device)) 12))

(definvariant soft-deleted-means-disabled :on end-device :check
              (if (eq (end-device-lifecycle end-device) :soft-deleted)
                  (not (end-device-enabled end-device))
                  t))

(definvariant active-means-enabled :on end-device :check
              (if (eq (end-device-lifecycle end-device) :active)
                  (end-device-enabled end-device)
                  t))

(definvariant soft-deletion-time-when-soft-deleted :on end-device :check
              (if (eq (end-device-lifecycle end-device) :soft-deleted)
                  (> (end-device-soft-deletion-time end-device) 0)
                  t))

(definvariant changed-time-positive :on end-device :check
              (> (end-device-changed-time end-device) 0))

(definvariant last-interaction-positive :on end-device :check
              (> (end-device-last-interaction-time end-device) 0))

(definvariant primacy-range :on der-program :check
              (and (>= (der-program-primacy der-program) 0)
                   (<= (der-program-primacy der-program) 255)))

(definvariant poll-rate-positive :on der-program :check (> (der-program-poll-rate der-program) 0))

(definvariant control-interval-positive :on der-control :check
              (> (der-control-interval-duration der-control) 0))

(definvariant control-creation-time-positive :on der-control :check
              (> (der-control-creation-time der-control) 0))

(definvariant control-start-positive :on der-control :check
              (> (der-control-interval-start der-control) 0))

(definvariant superseded-flag-consistency :on der-control :check
              (if (eq (der-control-event-status der-control) :superseded)
                  (der-control-potentially-superseded der-control)
                  t))

(definvariant superseded-time-consistency :on der-control :check
              (if (der-control-potentially-superseded der-control)
                  (> (der-control-potentially-superseded-time der-control) 0)
                  (= (der-control-potentially-superseded-time der-control) 0)))

(definvariant curve-min-points :on der-curve :check (>= (der-curve-point-count der-curve) 2))

(definvariant curve-type-valid :on der-curve :check
              (and (>= (der-curve-curve-type der-curve) 0)
                   (<= (der-curve-curve-type der-curve) 12)))

(definvariant curve-interval-positive :on der-curve :check
              (> (der-curve-interval-duration der-curve) 0))

(definvariant subscription-renewal-positive :on subscription :check
              (> (subscription-last-renewal-time subscription) 0))

(definvariant subscription-created-positive :on subscription :check
              (> (subscription-created-time subscription) 0))

(definvariant subscription-renewal-after-creation :on subscription :check
              (>= (subscription-last-renewal-time subscription)
                  (subscription-created-time subscription)))

(definvariant fsa-program-count-positive :on function-set-assignment :check
              (>= (function-set-assignment-program-count function-set-assignment) 1))

(definvariant mup-reading-count-non-negative :on mirror-usage-point :check
              (>= (mirror-usage-point-reading-count mirror-usage-point) 0))

(definvariant mup-last-post-positive :on mirror-usage-point :check
              (> (mirror-usage-point-last-post-time mirror-usage-point) 0))

(definvariant registration-datetime-positive :on registration :check
              (> (registration-date-time registration) 0))

(definvariant connection-point-id-non-empty :on connection-point :check
              (> (length (connection-point-connection-point-id connection-point)) 0))

(definvariant log-event-time-positive :on log-event :check (> (log-event-created-time log-event) 0))

(definvariant default-control-changed-time-positive :on default-der-control :check
              (> (default-der-control-changed-time default-der-control) 0))

(definvariant default-control-max-lim-w-non-negative :on default-der-control :check
              (>= (default-der-control-op-mod-max-lim-w default-der-control) 0))

(defscenario device-group-assignment :entities
             ((device 1 end-device) (fsas (1 3) function-set-assignment)
              (refs (1 15) der-program-ref) (programs (1 15) der-program)))

(defscenario control-supersession :entities
             ((program 1 der-program) (older-control 1 der-control) (newer-control 1 der-control)))

(defscenario aggregator-device-visibility :entities
             ((aggregator 1 end-device) (managed-ders (1 10) end-device)
              (other-ders (0 5) end-device)))

(defscenario device-subscriptions :entities ((device 1 end-device) (subs (0 10) subscription)))

(defscenario control-response-tracking :entities
             ((program 1 der-program) (control 1 der-control) (device 1 end-device)
              (responses (1 5) response)))

(definvariant device-group-count-min :on device-group-assignment :check (>= (length refs) 1))

(definvariant device-group-count-max :on device-group-assignment :check
              (<= (length refs) (config :max-groups-per-device)))

(definvariant fsa-count-matches-refs :on device-group-assignment :check
              (= (reduce #'+ fsas :key (lambda (f) (getf f :program-count))) (length refs)))

(definvariant programs-match-refs :on device-group-assignment :check
              (= (length programs) (length refs)))

(definvariant all-primacies-valid :on device-group-assignment :check
              (every (lambda (p) (and (>= (getf p :primacy) 0) (<= (getf p :primacy) 255)))
                     programs))

(definvariant newer-has-later-creation :on control-supersession :check
              (> (getf newer-control :creation-time) (getf older-control :creation-time)))

(definvariant overlapping-intervals :on control-supersession :check
              (and
               (< (getf older-control :interval-start)
                  (+ (getf newer-control :interval-start) (getf newer-control :interval-duration)))
               (< (getf newer-control :interval-start)
                  (+ (getf older-control :interval-start)
                     (getf older-control :interval-duration)))))

(definvariant older-is-superseded :on control-supersession :check
              (eq (getf older-control :event-status) :superseded))

(definvariant older-has-superseded-flag :on control-supersession :check
              (getf older-control :potentially-superseded))

(definvariant aggregator-is-aggregator-type :on aggregator-device-visibility :check
              (eq (getf aggregator :device-type) :aggregator))

(definvariant managed-ders-are-der-type :on aggregator-device-visibility :check
              (every (lambda (d) (eq (getf d :device-type) :der)) managed-ders))

(definvariant other-ders-are-der-type :on aggregator-device-visibility :check
              (every (lambda (d) (eq (getf d :device-type) :der)) other-ders))

(definvariant all-lfdi-unique :on aggregator-device-visibility :check
              (let ((all-lfdi
                     (cons (getf aggregator :lfdi)
                           (append (mapcar (lambda (d) (getf d :lfdi)) managed-ders)
                                   (mapcar (lambda (d) (getf d :lfdi)) other-ders)))))
                (= (length all-lfdi) (length (remove-duplicates all-lfdi :test #'string=)))))

(definvariant sub-count-within-limit :on device-subscriptions :check
              (<= (length subs) (config :subscription-max-per-client)))

(definvariant active-subs-have-valid-renewal :on device-subscriptions :check
              (every
               (lambda (s)
                 (if (eq (getf s :lifecycle) :active)
                     (> (getf s :last-renewal-time) 0)
                     t))
               subs))

(definvariant responses-reference-control :on control-response-tracking :check
              (every (lambda (r) (string= (getf r :subject-mrid) (getf control :mrid))) responses))

(definvariant device-is-der :on control-response-tracking :check
              (eq (getf device :device-type) :der))

(definvariant response-times-after-control-creation :on control-response-tracking :check
              (every (lambda (r) (>= (getf r :created-date-time) (getf control :creation-time)))
                     responses))

(defgenerator end-device
    (overrides)
  (let* ((lifecycle
          (or (getf overrides :lifecycle) (nth (random 3) '(:active :soft-deleted :hard-deleted))))
         (enabled (case lifecycle (:active t) (:soft-deleted nil) (:hard-deleted nil)))
         (soft-del-time (case lifecycle (:soft-deleted (+ 1000000 (random 1000000))) (t 0)))
         (lfdi
          (or (getf overrides :lfdi)
              (with-output-to-string (s) (dotimes (i 40) (format s "~(~x~)" (random 16))))))
         (sfdi
          (or (getf overrides :sfdi)
              (with-output-to-string (s) (dotimes (i 12) (format s "~d" (random 10))))))
         (changed-time (or (getf overrides :changed-time) (+ 1000000 (random 1000000))))
         (last-int-time (or (getf overrides :last-interaction-time) (+ 1000000 (random 1000000)))))
    (list :id (or (getf overrides :id) (format nil "ed-~a" (random 100000))) :lfdi lfdi :sfdi sfdi
          :device-type (or (getf overrides :device-type) (nth (random 2) '(:der :aggregator)))
          :enabled enabled :lifecycle lifecycle :changed-time changed-time :last-interaction-time
          last-int-time :soft-deletion-time soft-del-time :registered-via
          (or (getf overrides :registered-via) (nth (random 2) '(:in-band :out-of-band))))))

(defgenerator der-control
    (overrides)
  (let* ((creation-time (or (getf overrides :creation-time) (+ 1000000 (random 1000000))))
         (start (or (getf overrides :interval-start) (+ creation-time (random 100000))))
         (duration (or (getf overrides :interval-duration) (+ 60 (random 86340))))
         (status (or (getf overrides :event-status) :scheduled))
         (superseded (eq status :superseded))
         (ps-time
          (if superseded
              (+ creation-time (random 50000))
              0)))
    (list :id (or (getf overrides :id) (format nil "dc-~a" (random 100000))) :mrid
          (or (getf overrides :mrid) (format nil "E~7,'0d" (random 10000000))) :description
          (or (getf overrides :description) "") :creation-time creation-time :interval-start start
          :interval-duration duration :randomize-start (or (getf overrides :randomize-start) 0)
          :randomize-duration (or (getf overrides :randomize-duration) 0) :event-status status
          :potentially-superseded superseded :potentially-superseded-time ps-time :op-mod-max-lim-w
          (or (getf overrides :op-mod-max-lim-w) (random 10000)) :op-mod-connect t :op-mod-energize
          t :response-required t)))

(defscenario-generator device-group-assignment
    (overrides)
  (declare (ignore overrides))
  (let* ((max-groups (or (config :max-groups-per-device) 15))
         (num-programs (+ 1 (random max-groups)))
         (num-fsas (min 3 num-programs))
         (device (generate-instance "end-device" (list :device-type :der :lifecycle :active)))
         (programs
          (loop repeat num-programs
                collect (generate-instance "der-program")))
         (refs
          (loop for p in programs
                collect (generate-instance "der-program-ref")))
         (refs-per-fsa
          (let ((counts (make-list num-fsas :initial-element 0)))
            (loop for i below num-programs
                  do (incf (nth (mod i num-fsas) counts)))
            counts))
         (fsas
          (loop for
                count in refs-per-fsa
                collect (let ((fsa (generate-instance "function-set-assignment")))
                          (setf (getf fsa :program-count) count)
                          fsa))))
    (list :device device :fsas fsas :refs refs :programs programs)))

(defscenario-generator control-supersession
    (overrides)
  (declare (ignore overrides))
  (let* ((program (generate-instance "der-program"))
         (base-time (+ 1000000 (random 500000)))
         (overlap-start (+ base-time (random 10000)))
         (duration (+ 3600 (random 82800)))
         (older
          (generate-instance "der-control"
                             (list :creation-time base-time :interval-start overlap-start
                                   :interval-duration duration :event-status :superseded)))
         (newer
          (generate-instance "der-control"
                             (list :creation-time (+ base-time 1 (random 10000)) :interval-start
                                   (+ overlap-start (random (floor duration 2))) :interval-duration
                                   (+ 1800 (random 82800)) :event-status :active))))
    (list :program program :older-control older :newer-control newer)))

(defscenario-generator aggregator-device-visibility
    (overrides)
  (declare (ignore overrides))
  (let* ((used-lfdis nil)
         (make-unique-lfdi
          (lambda ()
            (loop for lfdi = (with-output-to-string (s)
                               (dotimes (i 40) (format s "~(~x~)" (random 16))))
                  while (member lfdi used-lfdis :test #'string=)
                  finally (push lfdi used-lfdis) (return lfdi))))
         (aggregator
          (generate-instance "end-device"
                             (list :device-type :aggregator :lifecycle :active :lfdi
                                   (funcall make-unique-lfdi))))
         (num-managed (+ 1 (random 10)))
         (num-other (random 6))
         (managed-ders
          (loop repeat num-managed
                collect (generate-instance "end-device"
                                           (list :device-type :der :lifecycle :active :lfdi
                                                 (funcall make-unique-lfdi)))))
         (other-ders
          (loop repeat num-other
                collect (generate-instance "end-device"
                                           (list :device-type :der :lifecycle :active :lfdi
                                                 (funcall make-unique-lfdi))))))
    (list :aggregator aggregator :managed-ders managed-ders :other-ders other-ders)))

(defscenario-generator device-subscriptions
    (overrides)
  (declare (ignore overrides))
  (let* ((device
          (generate-instance "end-device" (list :device-type :aggregator :lifecycle :active)))
         (max-subs (or (config :subscription-max-per-client) 10))
         (num-subs (random (1+ max-subs)))
         (subs
          (loop repeat num-subs
                collect (generate-instance "subscription"))))
    (list :device device :subs subs)))

(defscenario-generator control-response-tracking
    (overrides)
  (declare (ignore overrides))
  (let* ((program (generate-instance "der-program"))
         (control (generate-instance "der-control" (list :event-status :active)))
         (control-mrid (getf control :mrid))
         (control-creation (getf control :creation-time))
         (device (generate-instance "end-device" (list :device-type :der :lifecycle :active)))
         (num-responses (+ 1 (random 5)))
         (responses
          (loop repeat num-responses
                collect (let ((r (generate-instance "response")))
                          (setf (getf r :subject-mrid) control-mrid)
                          (setf (getf r :created-date-time) (+ control-creation (random 100000)))
                          r))))
    (list :program program :control control :device device :responses responses)))


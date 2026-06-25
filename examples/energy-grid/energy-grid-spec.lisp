;;; Energy Grid Dispatch — Behavioral Specification

(clear-specs)

;;;; Entities

(defentity generator ()
  (id string :required t :unique t)
  (name string :required t)
  (fuel-type (member :gas :coal :nuclear :hydro :wind :solar) :required t)
  (state (member :offline :starting :online :stopping :tripped) :default :offline)
  (output-mw number :default 0)
  (min-output number :required t)
  (max-output number :required t)
  (ramp-rate number :required t)
  (min-up-time number :required t)
  (min-down-time number :required t)
  (start-cost number :required t)
  (marginal-cost number :required t)
  (emissions-rate number :required t)
  (intervals-in-state number :default 0)
  (:belongs-to grid-zone)
  (:derived output-cost (lambda (g) (* (getf g :output-mw) (getf g :marginal-cost) (/ 1.0 12))))
  (:derived output-emissions (lambda (g) (* (getf g :output-mw) (getf g :emissions-rate) (/ 1.0 12))))
  (:derived can-increase (lambda (g)
    (if (eq (getf g :state) :online)
        (min (- (getf g :max-output) (getf g :output-mw))
             (* (getf g :ramp-rate) 5))
        0)))
  (:derived can-decrease (lambda (g)
    (if (eq (getf g :state) :online)
        (min (- (getf g :output-mw) (getf g :min-output))
             (* (getf g :ramp-rate) 5))
        0))))

(defentity storage-unit ()
  (id string :required t :unique t)
  (name string :required t)
  (state (member :idle :charging :discharging) :default :idle)
  (capacity-mwh number :required t)
  (soc number :required t)
  (max-charge-rate number :required t)
  (max-discharge-rate number :required t)
  (current-rate number :default 0)
  (round-trip-efficiency number :required t)
  (min-soc number :default 0.1)
  (max-soc number :default 0.95)
  (cycle-count number :default 0)
  (:belongs-to grid-zone)
  (:derived available-energy (lambda (s)
    (* (- (getf s :soc) (getf s :min-soc)) (getf s :capacity-mwh))))
  (:derived available-capacity (lambda (s)
    (* (- (getf s :max-soc) (getf s :soc)) (getf s :capacity-mwh))))
  (:derived soc-after-interval (lambda (s)
    (let* ((rate (getf s :current-rate))
           (eff (if (< rate 0) (getf s :round-trip-efficiency) 1.0)))
      (+ (getf s :soc) (/ (* rate eff) (* (getf s :capacity-mwh) 12)))))))

(defentity demand-response-contract ()
  (id string :required t :unique t)
  (customer string :required t)
  (priority-tier (member 1 2 3) :required t)
  (curtailable-mw number :required t)
  (activation-state (member :standby :notified :curtailed :restored) :default :standby)
  (min-notification-intervals number :required t)
  (max-curtailment-intervals number :required t)
  (intervals-in-state number :default 0)
  (compensation-rate number :required t)
  (:belongs-to grid-zone))

(defentity grid-zone ()
  (id string :required t :unique t)
  (name string :required t)
  (demand-mw number :required t)
  (demand-forecast-mw number :required t)
  (frequency-hz number :default 60.0)
  (import-limit-mw number :required t)
  (export-limit-mw number :required t)
  (transfer-mw number :default 0)
  (:has-many generators :of generator)
  (:has-many storage-units :of storage-unit)
  (:has-many demand-response-contracts :of demand-response-contract))

(defentity dispatch-interval ()
  (id string :required t :unique t)
  (timestamp string :required t)
  (state (member :pending :cleared :emergency :blackout) :default :pending)
  (total-demand-mw number :required t)
  (total-generation-mw number :required t)
  (total-storage-mw number :default 0)
  (total-curtailment-mw number :default 0)
  (system-imbalance-mw number :default 0)
  (system-frequency-hz number :default 60.0)
  (emissions-tons number :default 0)
  (total-cost number :default 0)
  (reserve-margin-pct number :default 0))

;;;; Rules — Generator state machine

(defrule start-generator
  :when (generator :state :offline)
  :requires ((>= (generator-intervals-in-state generator) (generator-min-down-time generator))
             (if (eq (generator-fuel-type generator) :nuclear)
                 (> (grid-zone-frequency-hz (generator-grid-zone generator)) 59.90)
                 t))
  :ensures ((eq (generator-state generator) :starting)))

(defrule sync-generator
  :when (generator :state :starting)
  :requires ((>= (generator-intervals-in-state generator)
                  (cond ((eq (generator-fuel-type generator) :nuclear) 24)
                        ((eq (generator-fuel-type generator) :coal) 6)
                        (t 2))))
  :ensures ((eq (generator-state generator) :online)))

(defrule stop-generator
  :when (generator :state :online)
  :requires ((>= (generator-intervals-in-state generator) (generator-min-up-time generator)))
  :ensures ((eq (generator-state generator) :stopping)))

(defrule complete-stop
  :when (generator :state :stopping)
  :requires ((>= (generator-intervals-in-state generator) 1))
  :ensures ((eq (generator-state generator) :offline)))

(defrule trip-generator
  :when (generator :state :online)
  :ensures ((eq (generator-state generator) :tripped)))

(defrule clear-trip
  :when (generator :state :tripped)
  :requires ((>= (generator-intervals-in-state generator) 6))
  :ensures ((eq (generator-state generator) :offline)))

(defrule ramp-generator
  :when (generator :state :online)
  :requires ((>= (generator-output-mw generator) (generator-min-output generator))
             (<= (generator-output-mw generator) (generator-max-output generator)))
  :ensures ((>= (generator-output-mw generator) (generator-min-output generator))
            (<= (generator-output-mw generator) (generator-max-output generator))))

;;;; Rules — Storage state machine

(defrule begin-charge
  :when (storage-unit :state :idle)
  :requires ((< (storage-unit-soc storage-unit) (storage-unit-max-soc storage-unit)))
  :ensures ((eq (storage-unit-state storage-unit) :charging)))

(defrule begin-discharge
  :when (storage-unit :state :idle)
  :requires ((> (storage-unit-soc storage-unit) (storage-unit-min-soc storage-unit)))
  :ensures ((eq (storage-unit-state storage-unit) :discharging)))

(defrule stop-charge
  :when (storage-unit :state :charging)
  :ensures ((eq (storage-unit-state storage-unit) :idle)))

(defrule stop-discharge
  :when (storage-unit :state :discharging)
  :ensures ((eq (storage-unit-state storage-unit) :idle)))

;;;; Rules — Demand-response state machine

(defrule notify-contract
  :when (demand-response-contract :activation-state :standby)
  :ensures ((eq (demand-response-contract-activation-state demand-response-contract) :notified)))

(defrule activate-contract
  :when (demand-response-contract :activation-state :notified)
  :requires ((>= (demand-response-contract-intervals-in-state demand-response-contract)
                  (demand-response-contract-min-notification-intervals demand-response-contract)))
  :ensures ((eq (demand-response-contract-activation-state demand-response-contract) :curtailed)))

(defrule release-contract
  :when (demand-response-contract :activation-state :curtailed)
  :ensures ((eq (demand-response-contract-activation-state demand-response-contract) :restored)))

(defrule restore-contract
  :when (demand-response-contract :activation-state :restored)
  :requires ((>= (demand-response-contract-intervals-in-state demand-response-contract) 2))
  :ensures ((eq (demand-response-contract-activation-state demand-response-contract) :standby)))

;;;; Rules — Dispatch interval state machine

(defrule clear-dispatch
  :when (dispatch-interval :state :pending)
  :requires ((<= (abs (dispatch-interval-system-imbalance-mw dispatch-interval)) 50)
             (>= (dispatch-interval-system-frequency-hz dispatch-interval) 59.95)
             (<= (dispatch-interval-system-frequency-hz dispatch-interval) 60.05)
             (>= (dispatch-interval-reserve-margin-pct dispatch-interval) 15))
  :ensures ((eq (dispatch-interval-state dispatch-interval) :cleared)))

(defrule declare-emergency
  :when (dispatch-interval :state :pending)
  :requires ((or (< (dispatch-interval-reserve-margin-pct dispatch-interval) 7)
                 (> (abs (dispatch-interval-system-imbalance-mw dispatch-interval)) 100)))
  :ensures ((eq (dispatch-interval-state dispatch-interval) :emergency)))

(defrule escalate-curtailment
  :when (dispatch-interval :state :emergency)
  :requires ((< (dispatch-interval-system-imbalance-mw dispatch-interval) -50))
  :ensures ((eq (dispatch-interval-state dispatch-interval) :emergency)))

(defrule declare-blackout
  :when (dispatch-interval :state :emergency)
  :requires ((< (dispatch-interval-system-imbalance-mw dispatch-interval) -200))
  :ensures ((eq (dispatch-interval-state dispatch-interval) :blackout)))

(defrule restore-from-blackout
  :when (dispatch-interval :state :blackout)
  :ensures ((eq (dispatch-interval-state dispatch-interval) :pending)))

(defrule resolve-emergency
  :when (dispatch-interval :state :emergency)
  :ensures ((eq (dispatch-interval-state dispatch-interval) :cleared)))

;;;; Invariants — Generator physics

(definvariant output-matches-state
  :on generator
  :check (if (not (eq (generator-state generator) :online))
             (= (generator-output-mw generator) 0)
             t))

(definvariant output-within-bounds
  :on generator
  :check (if (eq (generator-state generator) :online)
             (and (>= (generator-output-mw generator) (generator-min-output generator))
                  (<= (generator-output-mw generator) (generator-max-output generator)))
             t))

(definvariant positive-capacity
  :on generator
  :check (and (> (generator-max-output generator) 0)
              (>= (generator-min-output generator) 0)
              (< (generator-min-output generator) (generator-max-output generator))))

(definvariant ramp-rate-positive
  :on generator
  :check (> (generator-ramp-rate generator) 0))

(definvariant min-times-positive
  :on generator
  :check (and (> (generator-min-up-time generator) 0)
              (> (generator-min-down-time generator) 0)))

(definvariant emissions-non-negative
  :on generator
  :check (and (>= (generator-emissions-rate generator) 0)
              (if (member (generator-fuel-type generator) '(:hydro :wind :solar))
                  (= (generator-emissions-rate generator) 0)
                  (> (generator-emissions-rate generator) 0))))

(definvariant nuclear-constraints
  :on generator
  :check (if (eq (generator-fuel-type generator) :nuclear)
             (and (>= (generator-min-up-time generator) 24)
                  (>= (generator-min-down-time generator) 48)
                  (>= (generator-min-output generator) (* 0.5 (generator-max-output generator))))
             t))

;;;; Invariants — Storage physics

(definvariant soc-in-bounds
  :on storage-unit
  :check (and (>= (storage-unit-soc storage-unit) (storage-unit-min-soc storage-unit))
              (<= (storage-unit-soc storage-unit) (storage-unit-max-soc storage-unit))))

(definvariant rate-matches-state
  :on storage-unit
  :check (cond ((eq (storage-unit-state storage-unit) :idle)
                (= (storage-unit-current-rate storage-unit) 0))
               ((eq (storage-unit-state storage-unit) :charging)
                (< (storage-unit-current-rate storage-unit) 0))
               ((eq (storage-unit-state storage-unit) :discharging)
                (> (storage-unit-current-rate storage-unit) 0))
               (t t)))

(definvariant rate-within-limits
  :on storage-unit
  :check (cond ((eq (storage-unit-state storage-unit) :charging)
                (<= (abs (storage-unit-current-rate storage-unit))
                    (storage-unit-max-charge-rate storage-unit)))
               ((eq (storage-unit-state storage-unit) :discharging)
                (<= (storage-unit-current-rate storage-unit)
                    (storage-unit-max-discharge-rate storage-unit)))
               (t t)))

(definvariant efficiency-valid
  :on storage-unit
  :check (and (> (storage-unit-round-trip-efficiency storage-unit) 0)
              (<= (storage-unit-round-trip-efficiency storage-unit) 1.0)))

(definvariant soc-limits-ordered
  :on storage-unit
  :check (and (>= (storage-unit-min-soc storage-unit) 0)
              (< (storage-unit-min-soc storage-unit) (storage-unit-max-soc storage-unit))
              (<= (storage-unit-max-soc storage-unit) 1.0)))

(definvariant soc-after-valid
  :on storage-unit
  :check (let* ((rate (storage-unit-current-rate storage-unit))
                (eff (if (< rate 0)
                         (storage-unit-round-trip-efficiency storage-unit)
                         1.0))
                (soc-after (+ (storage-unit-soc storage-unit)
                              (/ (* rate eff)
                                 (* (storage-unit-capacity-mwh storage-unit) 12)))))
           (and (>= soc-after (storage-unit-min-soc storage-unit))
                (<= soc-after (storage-unit-max-soc storage-unit)))))

;;;; Invariants — Demand-response

(definvariant max-curtailment-duration
  :on demand-response-contract
  :check (if (eq (demand-response-contract-activation-state demand-response-contract) :curtailed)
             (<= (demand-response-contract-intervals-in-state demand-response-contract)
                 (demand-response-contract-max-curtailment-intervals demand-response-contract))
             t))

(definvariant compensation-positive
  :on demand-response-contract
  :check (> (demand-response-contract-compensation-rate demand-response-contract) 0))

;;;; Invariants — Grid balance

(definvariant cleared-means-balanced
  :on dispatch-interval
  :check (if (eq (dispatch-interval-state dispatch-interval) :cleared)
             (<= (abs (dispatch-interval-system-imbalance-mw dispatch-interval)) 50)
             t))

(definvariant frequency-reflects-imbalance
  :on dispatch-interval
  :check (let ((expected (+ 60.0 (* (dispatch-interval-system-imbalance-mw dispatch-interval) 0.001))))
           (<= (abs (- (dispatch-interval-system-frequency-hz dispatch-interval) expected)) 0.001)))

(definvariant reserve-margin-sane
  :on dispatch-interval
  :check (if (eq (dispatch-interval-state dispatch-interval) :cleared)
             (>= (dispatch-interval-reserve-margin-pct dispatch-interval) 15)
             t))

(definvariant emergency-threshold
  :on dispatch-interval
  :check (if (eq (dispatch-interval-state dispatch-interval) :emergency)
             (or (< (dispatch-interval-reserve-margin-pct dispatch-interval) 15)
                 (> (abs (dispatch-interval-system-imbalance-mw dispatch-interval)) 50))
             t))

;;;; Scenario — Cross-entity invariants

(defscenario full-dispatch
  :entities ((interval 1 dispatch-interval)
             (zones (1 3) grid-zone)
             (generators (3 24) generator)
             (storage-units (0 6) storage-unit)
             (contracts (0 12) demand-response-contract)))

(definvariant generation-totals-consistent
  :on full-dispatch
  :check (= (getf interval :total-generation-mw)
             (reduce #'+ generators :key (lambda (g) (getf g :output-mw)))))

(definvariant transfer-limits-respected
  :on full-dispatch
  :check (every (lambda (z)
                  (let ((xfer (getf z :transfer-mw)))
                    (if (> xfer 0)
                        (<= xfer (getf z :import-limit-mw))
                        (<= (abs xfer) (getf z :export-limit-mw)))))
                zones))

(definvariant transfer-net-zero
  :on full-dispatch
  :check (<= (abs (reduce #'+ zones :key (lambda (z) (getf z :transfer-mw)))) 0.01))

(definvariant curtailment-priority-order
  :on full-dispatch
  :check (every (lambda (z)
                  (let* ((zone-id (getf z :id))
                         (zone-contracts (remove-if-not
                                          (lambda (c) (equal (getf c :grid-zone-id) zone-id))
                                          contracts)))
                    (let ((any-t1-standby (some (lambda (c) (and (eql (getf c :priority-tier) 1)
                                                                  (eq (getf c :activation-state) :standby)))
                                                zone-contracts))
                          (any-t2-curtailed (some (lambda (c) (and (eql (getf c :priority-tier) 2)
                                                                    (eq (getf c :activation-state) :curtailed)))
                                                  zone-contracts))
                          (any-t2-standby (some (lambda (c) (and (eql (getf c :priority-tier) 2)
                                                                  (eq (getf c :activation-state) :standby)))
                                                zone-contracts))
                          (any-t3-curtailed (some (lambda (c) (and (eql (getf c :priority-tier) 3)
                                                                    (eq (getf c :activation-state) :curtailed)))
                                                  zone-contracts)))
                      (and (if any-t2-curtailed (not any-t1-standby) t)
                           (if any-t3-curtailed (not any-t2-standby) t)))))
                zones))

(definvariant emissions-match
  :on full-dispatch
  :check (<= (abs (- (getf interval :emissions-tons)
                      (reduce #'+ generators :key (lambda (g)
                        (* (getf g :output-mw) (getf g :emissions-rate) (/ 1.0 12))))))
              0.01))

(definvariant cost-match
  :on full-dispatch
  :check (let ((gen-cost (reduce #'+ generators :key (lambda (g)
                           (* (getf g :output-mw) (getf g :marginal-cost) (/ 1.0 12)))))
               (curtail-cost (reduce #'+ contracts :key (lambda (c)
                               (if (eq (getf c :activation-state) :curtailed)
                                   (* (getf c :curtailable-mw) (getf c :compensation-rate) (/ 1.0 12))
                                   0)))))
           (<= (abs (- (getf interval :total-cost) (+ gen-cost curtail-cost))) 0.01)))

(definvariant blackout-means-exhausted
  :on full-dispatch
  :check (if (eq (getf interval :state) :blackout)
             (and (every (lambda (c) (eq (getf c :activation-state) :curtailed)) contracts)
                  (= (reduce #'+ generators :key (lambda (g)
                       (if (eq (getf g :state) :online)
                           (min (- (getf g :max-output) (getf g :output-mw))
                                (* (getf g :ramp-rate) 5))
                           0)))
                     0))
             t))

;;;; Custom generators

(defgenerator generator (overrides)
  (let* ((fuel-type (or (cdr (assoc :fuel-type overrides))
                        (nth (random 6) '(:gas :coal :nuclear :hydro :wind :solar))))
         (nuclear-p (eq fuel-type :nuclear))
         (renewable-p (member fuel-type '(:hydro :wind :solar)))
         (max-output (or (cdr (assoc :max-output overrides))
                         (generate-value 'number :min 50.0 :max 1000.0)))
         (min-output (or (cdr (assoc :min-output overrides))
                         (if nuclear-p
                             (* 0.5 max-output)
                             (generate-value 'number :min 0.0 :max (* 0.4 max-output)))))
         (state (or (cdr (assoc :state overrides))
                    (nth (random 5) '(:offline :starting :online :stopping :tripped))))
         (output-mw (if (eq state :online)
                        (generate-value 'number :min min-output :max max-output)
                        0))
         (min-up-time (or (cdr (assoc :min-up-time overrides))
                          (if nuclear-p
                              (generate-value 'number :min 24.0 :max 48.0)
                              (generate-value 'number :min 1.0 :max 12.0))))
         (min-down-time (or (cdr (assoc :min-down-time overrides))
                            (if nuclear-p
                                (generate-value 'number :min 48.0 :max 96.0)
                                (generate-value 'number :min 1.0 :max 12.0))))
         (emissions-rate (if renewable-p 0 (generate-value 'number :min 0.1 :max 2.0))))
    (list :id (or (cdr (assoc :id overrides)) (generate-value 'string))
          :name (or (cdr (assoc :name overrides)) (generate-value 'string))
          :fuel-type fuel-type
          :state state
          :output-mw output-mw
          :min-output min-output
          :max-output max-output
          :ramp-rate (generate-value 'number :min 1.0 :max 50.0)
          :min-up-time min-up-time
          :min-down-time min-down-time
          :start-cost (generate-value 'number :min 1000.0 :max 100000.0)
          :marginal-cost (generate-value 'number :min 10.0 :max 200.0)
          :emissions-rate emissions-rate
          :intervals-in-state (generate-value 'number :min 0.0 :max 100.0))))

(defgenerator storage-unit (overrides)
  (let* ((state (or (cdr (assoc :state overrides))
                    (nth (random 3) '(:idle :charging :discharging))))
         (min-soc (or (cdr (assoc :min-soc overrides))
                      (generate-value 'number :min 0.05 :max 0.2)))
         (max-soc (or (cdr (assoc :max-soc overrides))
                      (generate-value 'number :min 0.85 :max 0.99)))
         (capacity-mwh (or (cdr (assoc :capacity-mwh overrides))
                           (generate-value 'number :min 10.0 :max 500.0)))
         (max-charge-rate (or (cdr (assoc :max-charge-rate overrides))
                              (generate-value 'number :min 5.0 :max 100.0)))
         (max-discharge-rate (or (cdr (assoc :max-discharge-rate overrides))
                                 (generate-value 'number :min 5.0 :max 100.0)))
         (efficiency (or (cdr (assoc :round-trip-efficiency overrides))
                         (generate-value 'number :min 0.85 :max 0.95)))
         (soc (cond ((eq state :charging)
                     (generate-value 'number :min (+ min-soc 0.05) :max (- max-soc 0.02)))
                    ((eq state :discharging)
                     (generate-value 'number :min (+ min-soc 0.02) :max (- max-soc 0.05)))
                    (t (generate-value 'number :min min-soc :max max-soc))))
         (current-rate
           (cond
             ((eq state :idle) 0)
             ((eq state :charging)
              (let* ((soc-headroom (* (- soc min-soc) capacity-mwh 12 (/ 1.0 efficiency)))
                     (safe-max (min max-charge-rate (max 0.1 soc-headroom))))
                (- (generate-value 'number :min 0.1 :max safe-max))))
             ((eq state :discharging)
              (let* ((soc-headroom (* (- max-soc soc) capacity-mwh 12))
                     (safe-max (min max-discharge-rate (max 0.1 soc-headroom))))
                (generate-value 'number :min 0.1 :max safe-max))))))
    (list :id (or (cdr (assoc :id overrides)) (generate-value 'string))
          :name (or (cdr (assoc :name overrides)) (generate-value 'string))
          :state state
          :capacity-mwh capacity-mwh
          :soc soc
          :max-charge-rate max-charge-rate
          :max-discharge-rate max-discharge-rate
          :current-rate current-rate
          :round-trip-efficiency efficiency
          :min-soc min-soc
          :max-soc max-soc
          :cycle-count (generate-value 'number :min 0.0 :max 5000.0))))

(defgenerator demand-response-contract (overrides)
  (let* ((tier (or (cdr (assoc :priority-tier overrides))
                   (nth (random 3) '(1 2 3))))
         (activation-state (or (cdr (assoc :activation-state overrides))
                               (nth (random 4) '(:standby :notified :curtailed :restored))))
         (min-notif (or (cdr (assoc :min-notification-intervals overrides))
                        (cond ((= tier 1) 1)
                              ((= tier 2) 3)
                              (t 6))))
         (max-curtail (or (cdr (assoc :max-curtailment-intervals overrides))
                          (generate-value 'number :min 6.0 :max 48.0)))
         (intervals-in-state (if (eq activation-state :curtailed)
                                 (generate-value 'number :min 0.0 :max max-curtail)
                                 (generate-value 'number :min 0.0 :max 20.0))))
    (list :id (or (cdr (assoc :id overrides)) (generate-value 'string))
          :customer (generate-value 'string)
          :priority-tier tier
          :curtailable-mw (generate-value 'number :min 1.0 :max 100.0)
          :activation-state activation-state
          :min-notification-intervals min-notif
          :max-curtailment-intervals max-curtail
          :intervals-in-state intervals-in-state
          :compensation-rate (generate-value 'number :min 10.0 :max 500.0))))

(defgenerator dispatch-interval (overrides)
  (let* ((state (or (cdr (assoc :state overrides))
                    (nth (random 4) '(:pending :cleared :emergency :blackout))))
         (imbalance (cond ((eq state :cleared)
                           (generate-value 'number :min -50.0 :max 50.0))
                          ((eq state :emergency)
                           (generate-value 'number :min -150.0 :max 150.0))
                          ((eq state :blackout)
                           (generate-value 'number :min -500.0 :max -200.0))
                          (t (generate-value 'number :min -200.0 :max 200.0))))
         (frequency (+ 60.0 (* imbalance 0.001)))
         (reserve-pct (cond ((eq state :cleared)
                             (generate-value 'number :min 15.0 :max 40.0))
                            ((eq state :emergency)
                             (generate-value 'number :min 0.0 :max 14.9))
                            (t (generate-value 'number :min 0.0 :max 50.0))))
         (total-demand (generate-value 'number :min 500.0 :max 5000.0))
         (total-gen (+ total-demand imbalance)))
    (list :id (generate-value 'string)
          :timestamp "2026-03-23T12:00:00Z"
          :state state
          :total-demand-mw total-demand
          :total-generation-mw (max 0 total-gen)
          :total-storage-mw 0
          :total-curtailment-mw 0
          :system-imbalance-mw imbalance
          :system-frequency-hz frequency
          :emissions-tons (generate-value 'number :min 0.0 :max 100.0)
          :total-cost (generate-value 'number :min 1000.0 :max 100000.0)
          :reserve-margin-pct reserve-pct)))

;;;; Scenario generator

(defscenario-generator full-dispatch (overrides)
  (declare (ignore overrides))
  (let* ((num-zones (+ 1 (random 3)))
         (zones '())
         (all-generators '())
         (all-storage '())
         (all-contracts '())
         (total-curtailment 0))
    (dotimes (zi num-zones)
      (let* ((zone-id (format nil "zone-~A" zi))
             (demand (generate-value 'number :min 200.0 :max 2000.0))
             (num-gens (+ 3 (random 6)))
             (zone-generators '()))
        (dotimes (gi num-gens)
          (let* ((fuel (nth (random 4) '(:gas :coal :hydro :wind)))
                 (max-out (generate-value 'number :min 50.0 :max 400.0))
                 (min-out (generate-value 'number :min 1.0 :max (* 0.3 max-out)))
                 (online-p (< (random 1.0) 0.7))
                 (state (if online-p :online :offline))
                 (target-output (if online-p
                                    (* (/ demand num-gens)
                                       (generate-value 'number :min 0.8 :max 1.2))
                                    0))
                 (output (if online-p
                             (min max-out (max min-out target-output))
                             0))
                 (emissions-rate (if (member fuel '(:hydro :wind :solar)) 0
                                     (generate-value 'number :min 0.1 :max 1.5))))
            (push (list :id (format nil "gen-~A-~A" zi gi)
                        :name (format nil "Generator ~A-~A" zi gi)
                        :fuel-type fuel :state state
                        :output-mw output :min-output min-out :max-output max-out
                        :ramp-rate (generate-value 'number :min 5.0 :max 30.0)
                        :min-up-time (generate-value 'number :min 1.0 :max 12.0)
                        :min-down-time (generate-value 'number :min 1.0 :max 12.0)
                        :start-cost (generate-value 'number :min 1000.0 :max 50000.0)
                        :marginal-cost (generate-value 'number :min 20.0 :max 150.0)
                        :emissions-rate emissions-rate
                        :intervals-in-state (generate-value 'number :min 1.0 :max 50.0)
                        :grid-zone-id zone-id)
                  zone-generators)))
        (let ((zone-storage '()))
          (dotimes (si (random 3))
            (let ((s (generate-instance "storage-unit"
                       (list (cons :id (format nil "stor-~A-~A" zi si))
                             (cons :name (format nil "Storage ~A-~A" zi si))))))
              (setf (getf s :grid-zone-id) zone-id)
              (push s zone-storage)))
          (let ((zone-curtail 0)
                (zone-contracts '()))
            (dolist (tier '(1 2 3))
              (when (< (length zone-contracts) (random 4))
                (let* ((lower-all-curtailed
                         (every (lambda (c) (eq (getf c :activation-state) :curtailed))
                                (remove-if-not
                                  (lambda (c) (< (getf c :priority-tier) tier))
                                  zone-contracts)))
                       (act-state (if (and (> tier 1) (not lower-all-curtailed))
                                      :standby
                                      (nth (random 2) '(:standby :curtailed))))
                       (c (generate-instance "demand-response-contract"
                            (list (cons :priority-tier tier)
                                  (cons :activation-state act-state)
                                  (cons :id (format nil "dr-~A-~A" zi tier))))))
                  (setf (getf c :grid-zone-id) zone-id)
                  (when (eq act-state :curtailed)
                    (incf zone-curtail (getf c :curtailable-mw)))
                  (push c zone-contracts))))
            (let ((zone (list :id zone-id
                              :name (format nil "Zone ~A" zi)
                              :demand-mw demand
                              :demand-forecast-mw (* demand (generate-value 'number :min 0.95 :max 1.05))
                              :frequency-hz 60.0
                              :import-limit-mw (generate-value 'number :min 200.0 :max 1000.0)
                              :export-limit-mw (generate-value 'number :min 200.0 :max 1000.0)
                              :transfer-mw 0)))
              (push zone zones)
              (incf total-curtailment zone-curtail)
              (setf all-generators (append zone-generators all-generators))
              (setf all-storage (append zone-storage all-storage))
              (setf all-contracts (append zone-contracts all-contracts)))))))
    (setf zones (nreverse zones))
    (when (> (length zones) 1)
      (let ((transfers (loop repeat (length zones) collect 0.0)))
        (loop for i from 0 below (1- (length zones))
              do (let* ((z1 (nth i zones))
                        (z2 (nth (1+ i) zones))
                        (flow (generate-value 'number :min -50.0 :max 50.0))
                        (clamped (max (- (getf z1 :export-limit-mw))
                                      (min (getf z1 :import-limit-mw) flow)))
                        (clamped2 (max (- (getf z2 :import-limit-mw))
                                       (min (getf z2 :export-limit-mw) (- clamped)))))
                   (setf (nth i transfers) (- clamped2))
                   (setf (nth (1+ i) transfers) clamped2)))
        (let ((sum (reduce #'+ transfers)))
          (unless (< (abs sum) 0.01)
            (loop for i from 0 below (length zones)
                  do (decf (nth i transfers) (/ sum (length zones))))))
        (loop for z in zones
              for xfer in transfers
              do (setf (getf z :transfer-mw)
                       (if (> xfer 0)
                           (min xfer (getf z :import-limit-mw))
                           (max xfer (- (getf z :export-limit-mw))))))))
    (let ((transfer-sum (reduce #'+ zones :key (lambda (z) (getf z :transfer-mw)))))
      (when (> (abs transfer-sum) 0.001)
        (decf (getf (first zones) :transfer-mw) transfer-sum)))
    (let* ((total-gen (reduce #'+ all-generators
                              :key (lambda (g) (getf g :output-mw))))
           (total-storage-net (reduce #'+ all-storage
                                      :key (lambda (s) (getf s :current-rate))
                                      :initial-value 0))
           (total-demand (reduce #'+ zones :key (lambda (z) (getf z :demand-mw))))
           (total-transfer (reduce #'+ zones :key (lambda (z) (getf z :transfer-mw))))
           (imbalance (- (+ total-gen total-storage-net total-curtailment total-transfer)
                         total-demand))
           (frequency (+ 60.0 (* imbalance 0.001)))
           (reserve-pct (if (> total-demand 0) (* 100.0 (/ total-gen total-demand)) 20.0))
           (di-state (cond ((and (<= (abs imbalance) 50) (>= reserve-pct 15)) :cleared)
                           ((or (< reserve-pct 7) (> (abs imbalance) 100)) :emergency)
                           (t :pending)))
           (total-emissions (reduce #'+ all-generators
                                    :key (lambda (g) (* (getf g :output-mw)
                                                        (getf g :emissions-rate)
                                                        (/ 1.0 12)))))
           (total-cost (+ (reduce #'+ all-generators
                                  :key (lambda (g) (* (getf g :output-mw)
                                                      (getf g :marginal-cost)
                                                      (/ 1.0 12))))
                          (reduce #'+ all-contracts
                                  :key (lambda (c)
                                    (if (eq (getf c :activation-state) :curtailed)
                                        (* (getf c :curtailable-mw)
                                           (getf c :compensation-rate)
                                           (/ 1.0 12))
                                        0))))))
      (list :interval (list :id "interval-0"
                            :timestamp "2026-03-23T12:00:00Z"
                            :state di-state
                            :total-demand-mw total-demand
                            :total-generation-mw total-gen
                            :total-storage-mw total-storage-net
                            :total-curtailment-mw total-curtailment
                            :system-imbalance-mw imbalance
                            :system-frequency-hz frequency
                            :emissions-tons total-emissions
                            :total-cost total-cost
                            :reserve-margin-pct reserve-pct)
            :zones zones
            :generators all-generators
            :storage-units all-storage
            :contracts all-contracts))))

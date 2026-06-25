(clear-specs)

(defentity aircraft ()
  (id string :required t :unique t)
  (registration string :required t)
  (type (member :single-engine :twin-engine :turboprop) :required t)
  (basic-empty-weight number :required t)
  (basic-empty-moment number :required t)
  (max-takeoff-weight number :required t)
  (max-landing-weight number :required t)
  (max-zero-fuel-weight number :required t)
  (forward-cg-limit number :required t)
  (aft-cg-limit number :required t))

(defentity performance-profile ()
  (id string :required t :unique t)
  (climb-burn-rate number :required t)
  (cruise-burn-rate number :required t)
  (descent-burn-rate number :required t)
  (climb-tas number :required t)
  (cruise-tas number :required t)
  (descent-tas number :required t)
  (rate-of-climb number :required t)
  (rate-of-descent number :required t)
  (service-ceiling number :required t)
  (vs0 number :required t)
  (vs1 number :required t)
  (vx number :required t)
  (vy number :required t)
  (va number :required t)
  (vne number :required t)
  (vfe number :required t))

(defentity load-item ()
  (id string :required t :unique t)
  (description string :required t)
  (weight number :required t)
  (arm number :required t)
  (moment number :required t)
  (category (member :pilot :passenger :baggage :cargo) :required t)
  (zone (member :forward :aft :left :right) :required t))

(defentity fuel-load ()
  (id string :required t :unique t)
  (fuel-weight number :required t)
  (fuel-arm number :required t)
  (fuel-moment number :required t)
  (max-fuel-capacity number :required t))

(defentity flight-leg ()
  (id string :required t :unique t)
  (sequence number :required t)
  (from-waypoint string :required t)
  (to-waypoint string :required t)
  (planned-altitude number :required t)
  (distance number :required t)
  (fuel-burn number :required t)
  (estimated-time number :required t))

(defentity dispatch ()
  (id string :required t :unique t)
  (state (member :draft :computed :approved :rejected) :default :draft)
  (pilot-in-command string :required t)
  (total-weight number :required t)
  (total-moment number :required t)
  (cg-position number :required t)
  (landing-weight number :required t)
  (landing-moment number :required t)
  (landing-cg number :required t)
  (total-fuel-burn number :required t)
  (total-flight-time number :required t)
  (min-fuel-remaining number :required t)
  (reserve-fuel-required number :required t))

(defrule compute-dispatch
  :when (dispatch :state :draft)
  :ensures ((eq (dispatch-state dispatch) :computed)))

(defrule approve-dispatch
  :when (dispatch :state :computed)
  :requires ((>= (dispatch-min-fuel-remaining dispatch) (dispatch-reserve-fuel-required dispatch)))
  :ensures ((eq (dispatch-state dispatch) :approved)))

(defrule reject-dispatch
  :when (dispatch :state :computed)
  :ensures ((eq (dispatch-state dispatch) :rejected)))

(defrule recompute-dispatch
  :when (dispatch :state :computed)
  :ensures ((eq (dispatch-state dispatch) :draft)))

(defrule recompute-dispatch-from-rejected
  :when (dispatch :state :rejected)
  :ensures ((eq (dispatch-state dispatch) :draft)))

(definvariant moment-is-weight-times-arm
  :on load-item
  :check (= (getf load-item :moment) (* (getf load-item :weight) (getf load-item :arm))))

(definvariant fuel-moment-correct
  :on fuel-load
  :check (= (getf fuel-load :fuel-moment) (* (getf fuel-load :fuel-weight) (getf fuel-load :fuel-arm))))

(definvariant positive-weights
  :on load-item
  :check (> (getf load-item :weight) 0))

(definvariant fuel-within-capacity
  :on fuel-load
  :check (and (>= (getf fuel-load :fuel-weight) 0)
              (<= (getf fuel-load :fuel-weight) (getf fuel-load :max-fuel-capacity))))

(definvariant cg-limits-ordered
  :on aircraft
  :check (< (getf aircraft :forward-cg-limit) (getf aircraft :aft-cg-limit)))

(definvariant weight-limits-ordered
  :on aircraft
  :check (<= (getf aircraft :max-landing-weight) (getf aircraft :max-takeoff-weight)))

(definvariant zero-fuel-weight-bounded
  :on aircraft
  :check (<= (getf aircraft :max-zero-fuel-weight) (getf aircraft :max-takeoff-weight)))

(definvariant speeds-ordered
  :on performance-profile
  :check (and (< (getf performance-profile :vs0) (getf performance-profile :vs1))
              (< (getf performance-profile :vs1) (getf performance-profile :vx))
              (< (getf performance-profile :vx) (getf performance-profile :vy))
              (< (getf performance-profile :vy) (getf performance-profile :va))
              (< (getf performance-profile :va) (getf performance-profile :vne))))

(definvariant climb-faster-than-stall
  :on performance-profile
  :check (> (getf performance-profile :climb-tas) (getf performance-profile :vs1)))

(definvariant cruise-faster-than-climb
  :on performance-profile
  :check (> (getf performance-profile :cruise-tas) (getf performance-profile :climb-tas)))

(definvariant positive-burn-rates
  :on performance-profile
  :check (and (> (getf performance-profile :climb-burn-rate) 0)
              (> (getf performance-profile :cruise-burn-rate) 0)
              (> (getf performance-profile :descent-burn-rate) 0)))

(definvariant positive-rates
  :on performance-profile
  :check (and (> (getf performance-profile :rate-of-climb) 0)
              (> (getf performance-profile :rate-of-descent) 0)))

(definvariant positive-leg-distance
  :on flight-leg
  :check (> (getf flight-leg :distance) 0))

(definvariant positive-fuel-burn
  :on flight-leg
  :check (> (getf flight-leg :fuel-burn) 0))

(definvariant approved-within-limits
  :on dispatch
  :check (if (eq (getf dispatch :state) :approved)
             (and (> (getf dispatch :total-weight) 0)
                  (> (getf dispatch :landing-weight) 0)
                  (<= (getf dispatch :landing-weight) (getf dispatch :total-weight)))
             t))

(definvariant dispatch-cg-sane
  :on dispatch
  :check (if (or (eq (getf dispatch :state) :approved)
                 (eq (getf dispatch :state) :computed))
             (> (getf dispatch :cg-position) 0)
             t))

(definvariant fuel-reserves-met
  :on dispatch
  :check (if (eq (getf dispatch :state) :approved)
             (>= (getf dispatch :min-fuel-remaining) (getf dispatch :reserve-fuel-required))
             t))

(definvariant landing-fuel-non-negative
  :on dispatch
  :check (if (or (eq (getf dispatch :state) :computed)
                 (eq (getf dispatch :state) :approved))
             (< (getf dispatch :landing-weight) (getf dispatch :total-weight))
             t))

(defparameter *aircraft-profiles*
  '((:c172s
     :type :single-engine
     :basic-empty-weight 1663.0 :basic-empty-moment 156476.0
     :max-takeoff-weight 2550.0 :max-landing-weight 2550.0 :max-zero-fuel-weight 2550.0
     :forward-cg-limit 35.0 :aft-cg-limit 47.3)
    (:be58
     :type :twin-engine
     :basic-empty-weight 3322.0 :basic-empty-moment 444114.0
     :max-takeoff-weight 5400.0 :max-landing-weight 5200.0 :max-zero-fuel-weight 5000.0
     :forward-cg-limit 85.0 :aft-cg-limit 95.0)
    (:pc-12
     :type :turboprop
     :basic-empty-weight 5765.0 :basic-empty-moment 1095350.0
     :max-takeoff-weight 10450.0 :max-landing-weight 10250.0 :max-zero-fuel-weight 9700.0
     :forward-cg-limit 140.0 :aft-cg-limit 160.0)))

(defparameter *perf-profiles*
  '((:c172s
     :vs0 40.0 :vs1 48.0 :vx 62.0 :vy 74.0 :va 99.0 :vne 163.0 :vfe 85.0
     :climb-burn-rate 61.0 :cruise-burn-rate 50.0 :descent-burn-rate 27.0
     :climb-tas 75.0 :cruise-tas 122.0 :descent-tas 105.0
     :rate-of-climb 730.0 :rate-of-descent 500.0 :service-ceiling 14000.0)
    (:be58
     :vs0 69.0 :vs1 78.0 :vx 84.0 :vy 96.0 :va 140.0 :vne 223.0 :vfe 130.0
     :climb-burn-rate 216.0 :cruise-burn-rate 144.0 :descent-burn-rate 60.0
     :climb-tas 120.0 :cruise-tas 195.0 :descent-tas 150.0
     :rate-of-climb 1700.0 :rate-of-descent 800.0 :service-ceiling 20700.0)
    (:pc-12
     :vs0 67.0 :vs1 80.0 :vx 110.0 :vy 120.0 :va 155.0 :vne 240.0 :vfe 170.0
     :climb-burn-rate 476.0 :cruise-burn-rate 272.0 :descent-burn-rate 122.0
     :climb-tas 160.0 :cruise-tas 260.0 :descent-tas 200.0
     :rate-of-climb 1920.0 :rate-of-descent 1200.0 :service-ceiling 30000.0)))

(defgenerator aircraft (overrides)
  (declare (ignore overrides))
  (let* ((idx (random 3))
         (p (rest (nth idx *aircraft-profiles*))))
    (list :id (generate-value 'string)
          :registration (generate-value 'string)
          :type (getf p :type)
          :basic-empty-weight (getf p :basic-empty-weight)
          :basic-empty-moment (getf p :basic-empty-moment)
          :max-takeoff-weight (getf p :max-takeoff-weight)
          :max-landing-weight (getf p :max-landing-weight)
          :max-zero-fuel-weight (getf p :max-zero-fuel-weight)
          :forward-cg-limit (getf p :forward-cg-limit)
          :aft-cg-limit (getf p :aft-cg-limit))))

(defgenerator performance-profile (overrides)
  (declare (ignore overrides))
  (let* ((idx (random 3))
         (p (rest (nth idx *perf-profiles*))))
    (list :id (generate-value 'string)
          :vs0 (getf p :vs0) :vs1 (getf p :vs1)
          :vx (getf p :vx) :vy (getf p :vy)
          :va (getf p :va) :vne (getf p :vne) :vfe (getf p :vfe)
          :climb-burn-rate (getf p :climb-burn-rate)
          :cruise-burn-rate (getf p :cruise-burn-rate)
          :descent-burn-rate (getf p :descent-burn-rate)
          :climb-tas (getf p :climb-tas)
          :cruise-tas (getf p :cruise-tas)
          :descent-tas (getf p :descent-tas)
          :rate-of-climb (getf p :rate-of-climb)
          :rate-of-descent (getf p :rate-of-descent)
          :service-ceiling (getf p :service-ceiling))))

(defgenerator load-item (overrides)
  (declare (ignore overrides))
  (let* ((cat (nth (random 4) '(:pilot :passenger :baggage :cargo)))
         (weight (if (member cat '(:pilot :passenger))
                     (generate-value 'number :min 100.0 :max 250.0)
                     (generate-value 'number :min 5.0 :max 120.0)))
         (arm (generate-value 'number :min 36.0 :max 159.0))
         (moment (* weight arm)))
    (list :id (generate-value 'string)
          :description (generate-value 'string)
          :weight weight
          :arm arm
          :moment moment
          :category cat
          :zone (nth (random 4) '(:forward :aft :left :right)))))

(defgenerator fuel-load (overrides)
  (declare (ignore overrides))
  (let* ((max-cap (generate-value 'number :min 100.0 :max 1500.0))
         (fw (generate-value 'number :min 0.0 :max max-cap))
         (fa (generate-value 'number :min 36.0 :max 159.0))
         (fm (* fw fa)))
    (list :id (generate-value 'string)
          :fuel-weight fw
          :fuel-arm fa
          :fuel-moment fm
          :max-fuel-capacity max-cap)))

(defgenerator flight-leg (overrides)
  (declare (ignore overrides))
  (list :id (generate-value 'string)
        :sequence (+ 1 (random 10))
        :from-waypoint (generate-value 'string)
        :to-waypoint (generate-value 'string)
        :planned-altitude (generate-value 'number :min 1000.0 :max 30000.0)
        :distance (generate-value 'number :min 50.0 :max 500.0)
        :fuel-burn (generate-value 'number :min 5.0 :max 100.0)
        :estimated-time (generate-value 'number :min 0.3 :max 3.0)))

(defgenerator dispatch (overrides)
  (declare (ignore overrides))
  (let* ((state (nth (random 4) '(:draft :computed :approved :rejected)))
         (total-weight (generate-value 'number :min 1500.0 :max 10000.0))
         (fuel-burn (generate-value 'number :min 10.0 :max 500.0))
         (landing-weight (- total-weight fuel-burn))
         (reserve (generate-value 'number :min 10.0 :max 100.0))
         (min-fuel (if (eq state :approved)
                       (+ reserve (generate-value 'number :min 1.0 :max 50.0))
                       (generate-value 'number :min 0.0 :max 200.0)))
         (cg (generate-value 'number :min 36.0 :max 159.0))
         (total-moment (* total-weight cg))
         (landing-cg (generate-value 'number :min 36.0 :max 159.0))
         (landing-moment (* landing-weight landing-cg)))
    (list :id (generate-value 'string)
          :state state
          :pilot-in-command (generate-value 'string)
          :total-weight total-weight
          :total-moment total-moment
          :cg-position cg
          :landing-weight landing-weight
          :landing-moment landing-moment
          :landing-cg landing-cg
          :total-fuel-burn fuel-burn
          :total-flight-time (generate-value 'number :min 0.5 :max 8.0)
          :min-fuel-remaining min-fuel
          :reserve-fuel-required reserve)))

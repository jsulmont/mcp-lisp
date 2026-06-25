(defentity track-section
    nil
  (id string :required t :unique t)
  (name string :required t)
  (state (member :clear :occupied) :default :clear)
  (length-m number :required t)
  (locked-by string :default ""))

(defentity point
    nil
  (id string :required t :unique t)
  (name string :required t)
  (position (member :normal :reverse))
  (commanded (member :normal :reverse))
  (detected boolean :default t)
  (locked boolean :default nil)
  (locked-by string :default "")
  (failed boolean :default nil))

(defentity signal
    nil
  (id string :required t :unique t)
  (name string :required t)
  (aspect (member :danger :proceed :caution :preliminary-caution) :default :danger)
  (replacement-active boolean :default nil)
  (approach-locked boolean :default nil))

(defentity route
    nil
  (id string :required t :unique t)
  (name string :required t)
  (entry-signal string :required t)
  (exit-signal string :default "")
  (state (member :free :requesting :locked :set) :default :free)
  (sections list :required t)
  (point-positions list :default nil)
  (flank-protections list :default nil)
  (overlap-sections list :default nil)
  (overlap-points list :default nil)
  (conflicts-with list :default nil)
  (approach-locked boolean :default nil)
  (timeout-s number :default 120)
  (:has-many route-sections :of track-section)
  (:has-many route-points :of point))

(defentity train
    nil
  (id string :required t :unique t)
  (name string :required t)
  (state (member :stopped :moving :approaching) :default :stopped)
  (speed-kmh number :default 0)
  (heading (member :up :down))
  (current-sections list :default nil)
  (authority-route string :default "")
  (berth string :default ""))

(defconfig
  (approach-lock-timeout number :default 120 :min 30 :max 300)
  (overlap-hold-time number :default 120 :min 60 :max 300)
  (point-detection-timeout number :default 8 :min 3 :max 30)
  (route-release-mode (member :sequential :full) :default :sequential)
  (signal-replacement-timeout number :default 60 :min 30 :max 120)
  (max-approach-speed number :default 160 :min 40 :max 300))

(defrule request-route :when (route :state :free) :requires
         ((every
           (lambda (sid)
             (let ((sec (find-instance "track-section" sid)))
               (and sec (eq (getf sec :state) :clear))))
           (route-sections route))
          (every
           (lambda (rid)
             (let ((r (find-instance "route" rid)))
               (and r (not (member (getf r :state) '(:locked :set))))))
           (route-conflicts-with route))
          (let ((sig (find-instance "signal" (route-entry-signal route))))
            (and sig (eq (getf sig :aspect) :danger))))
         :ensures ((eq (route-state route) :requesting)))

(defrule lock-route :when (route :state :requesting) :requires
         ((every
           (lambda (pp)
             (let ((p (find-instance "point" (getf pp :point-id))))
               (and p (eq (getf p :position) (getf pp :required-position)) (getf p :detected)
                    (not (getf p :failed)))))
           (route-point-positions route))
          (every
           (lambda (fp)
             (let ((p (find-instance "point" (getf fp :point-id))))
               (and p (eq (getf p :position) (getf fp :required-position)) (getf p :detected)
                    (not (getf p :failed)))))
           (route-flank-protections route))
          (every
           (lambda (sid)
             (let ((sec (find-instance "track-section" sid)))
               (and sec (eq (getf sec :state) :clear))))
           (route-sections route))
          (every
           (lambda (rid)
             (let ((r (find-instance "route" rid)))
               (and r (not (member (getf r :state) '(:locked :set))))))
           (route-conflicts-with route)))
         :ensures ((eq (route-state route) :locked)))

(defrule set-route :when (route :state :locked) :requires
         ((every
           (lambda (sid)
             (let ((sec (find-instance "track-section" sid)))
               (and sec (eq (getf sec :state) :clear))))
           (route-overlap-sections route))
          (every
           (lambda (op)
             (let ((p (find-instance "point" (getf op :point-id))))
               (and p (eq (getf p :position) (getf op :required-position)) (getf p :detected))))
           (route-overlap-points route))
          (every
           (lambda (sid)
             (let ((sec (find-instance "track-section" sid)))
               (and sec (eq (getf sec :state) :clear))))
           (route-sections route)))
         :ensures ((eq (route-state route) :set)))

(defrule cancel-route :when (route :state (member :requesting :locked)) :requires
         ((not (route-approach-locked route))
          (let ((sig (find-instance "signal" (route-entry-signal route))))
            (and sig (eq (getf sig :aspect) :danger))))
         :ensures ((eq (route-state route) :free)))

(defrule approach-lock-route :when (route :state :set) :requires
         ((let ((sig (find-instance "signal" (route-entry-signal route))))
            (and sig (not (eq (getf sig :aspect) :danger)))))
         :sets ((route-approach-locked route) t) :ensures ((eq (route-state route) :set)))

(defrule release-route-sequential :when (route :state :set) :requires
         ((eq (config :route-release-mode) :sequential)) :ensures ((eq (route-state route) :free)))

(defrule release-route-full :when (route :state :set) :requires
         ((eq (config :route-release-mode) :full)) :ensures ((eq (route-state route) :free)))

(defrule emergency-replacement :when (signal :aspect :danger) :requires
         ((signal-replacement-active signal)) :sets ((signal-aspect signal) :caution) :ensures
         ((eq (signal-aspect signal) :caution)))

(defrule train-enter :when (train :state (member :stopped :approaching)) :requires
         ((<= (train-speed-kmh train) (config :max-approach-speed))) :ensures
         ((eq (train-state train) :moving)))

(defrule train-stop :when (train :state :moving) :sets ((train-speed-kmh train) 0) :ensures
         ((eq (train-state train) :stopped)))

(definvariant point-lock-position-match :on point :check
              (if (point-locked point)
                  (and (eq (point-position point) (point-commanded point)) (point-detected point))
                  t))

(definvariant point-single-lock :on point :check
              (if (string= (point-locked-by point) "")
                  (not (point-locked point))
                  (point-locked point)))

(definvariant point-no-move-when-locked :on point :check
              (if (point-locked point)
                  (eq (point-commanded point) (point-position point))
                  t))

(definvariant approach-lock-requires-set :on route :check
              (if (route-approach-locked route)
                  (eq (route-state route) :set)
                  t))

(definvariant section-length-positive :on track-section :check
              (> (track-section-length-m track-section) 0))

(definvariant train-speed-non-negative :on train :check (>= (train-speed-kmh train) 0))

(definvariant stopped-means-zero-speed :on train :check
              (if (eq (train-state train) :stopped)
                  (= (train-speed-kmh train) 0)
                  t))

(definvariant train-speed-within-max :on train :check
              (<= (train-speed-kmh train) (config :max-approach-speed)))

(defscenario junction-interlocking :entities
             ((sections (8 15) track-section) (points (3 6) point) (signals (4 10) signal)
              (routes (6 12) route) (trains (1 4) train)))

(definvariant failed-point-blocks-route :on junction-interlocking :check
              (let ((failed-point-ids
                     (mapcar (lambda (p) (getf p :id))
                             (remove-if-not (lambda (p) (getf p :failed)) points))))
                (every
                 (lambda (r)
                   (if (member (getf r :state) '(:locked :set))
                       (and
                        (every
                         (lambda (pp)
                           (not (member (getf pp :point-id) failed-point-ids :test #'string=)))
                         (getf r :point-positions))
                        (every
                         (lambda (op)
                           (not (member (getf op :point-id) failed-point-ids :test #'string=)))
                         (getf r :overlap-points)))
                       t))
                 routes)))

(definvariant danger-when-no-route :on junction-interlocking :check
              (every
               (lambda (sig)
                 (let ((has-set-route
                        (some
                         (lambda (r)
                           (and (string= (getf r :entry-signal) (getf sig :id))
                                (eq (getf r :state) :set)))
                         routes)))
                   (if (not has-set-route)
                       (eq (getf sig :aspect) :danger)
                       t)))
               signals))

(definvariant one-route-per-signal :on junction-interlocking :check
              (every
               (lambda (sig)
                 (<=
                  (count-if
                   (lambda (r)
                     (and (string= (getf r :entry-signal) (getf sig :id))
                          (eq (getf r :state) :set)))
                   routes)
                  1))
               signals))

(definvariant aspect-hierarchy-consistency :on junction-interlocking :check
              (every
               (lambda (r)
                 (if (eq (getf r :state) :set)
                     (let* ((entry-sig
                             (find-if (lambda (s) (string= (getf s :id) (getf r :entry-signal)))
                                      signals))
                            (exit-sig
                             (if (string= (getf r :exit-signal) "")
                                 nil
                                 (find-if (lambda (s) (string= (getf s :id) (getf r :exit-signal)))
                                          signals)))
                            (entry-aspect (and entry-sig (getf entry-sig :aspect))))
                       (cond
                        ((eq entry-aspect :proceed)
                         (and exit-sig (member (getf exit-sig :aspect) '(:proceed :caution))))
                        ((eq entry-aspect :caution)
                         (or (null exit-sig) (and exit-sig (eq (getf exit-sig :aspect) :danger))))
                        (t t)))
                     t))
               routes))

(definvariant route-mutual-exclusion :on junction-interlocking :check
              (every
               (lambda (r)
                 (if (member (getf r :state) '(:locked :set))
                     (every
                      (lambda (cid)
                        (let ((cr (find-if (lambda (x) (string= (getf x :id) cid)) routes)))
                          (or (null cr) (not (member (getf cr :state) '(:locked :set))))))
                      (getf r :conflicts-with))
                     t))
               routes))

(definvariant conflict-symmetry :on junction-interlocking :check
              (every
               (lambda (r)
                 (every
                  (lambda (cid)
                    (let ((cr (find-if (lambda (x) (string= (getf x :id) cid)) routes)))
                      (and cr (member (getf r :id) (getf cr :conflicts-with) :test #'string=))))
                  (getf r :conflicts-with)))
               routes))

(definvariant conflict-completeness :on junction-interlocking :check
              (every
               (lambda (r1)
                 (every
                  (lambda (r2)
                    (if (string= (getf r1 :id) (getf r2 :id))
                        t
                        (let* ((shared-section
                                (some (lambda (s1) (member s1 (getf r2 :sections) :test #'string=))
                                      (getf r1 :sections)))
                               (all-pp1
                                (append (getf r1 :point-positions) (getf r1 :flank-protections)))
                               (all-pp2
                                (append (getf r2 :point-positions) (getf r2 :flank-protections)))
                               (conflicting-point
                                (some
                                 (lambda (pp1)
                                   (some
                                    (lambda (pp2)
                                      (and (string= (getf pp1 :point-id) (getf pp2 :point-id))
                                           (not
                                            (eq (getf pp1 :required-position)
                                                (getf pp2 :required-position)))))
                                    all-pp2))
                                 all-pp1)))
                          (if (or shared-section conflicting-point)
                              (member (getf r2 :id) (getf r1 :conflicts-with) :test #'string=)
                              t))))
                  routes))
               routes))

(definvariant locked-sections-held :on junction-interlocking :check
              (every
               (lambda (r)
                 (if (member (getf r :state) '(:locked :set))
                     (every
                      (lambda (sid)
                        (let ((sec (find-if (lambda (s) (string= (getf s :id) sid)) sections)))
                          (and sec (string= (getf sec :locked-by) (getf r :id)))))
                      (getf r :sections))
                     t))
               routes))

(definvariant locked-points-held :on junction-interlocking :check
              (every
               (lambda (r)
                 (if (member (getf r :state) '(:locked :set))
                     (every
                      (lambda (pp)
                        (let ((p
                               (find-if (lambda (x) (string= (getf x :id) (getf pp :point-id)))
                                        points)))
                          (and p (getf p :locked) (string= (getf p :locked-by) (getf r :id)))))
                      (getf r :point-positions))
                     t))
               routes))

(definvariant set-requires-overlap-clear :on junction-interlocking :check
              (every
               (lambda (r)
                 (if (eq (getf r :state) :set)
                     (every
                      (lambda (sid)
                        (let ((sec (find-if (lambda (s) (string= (getf s :id) sid)) sections)))
                          (and sec (eq (getf sec :state) :clear))))
                      (getf r :overlap-sections))
                     t))
               routes))

(definvariant no-route-into-occupied :on junction-interlocking :check
              (every
               (lambda (sec)
                 (if (eq (getf sec :state) :occupied)
                     (or (string= (getf sec :locked-by) "")
                         (some
                          (lambda (r)
                            (and (string= (getf r :id) (getf sec :locked-by))
                                 (member (getf r :state) '(:locked :set))))
                          routes))
                     t))
               sections))

(definvariant train-sections-occupied :on junction-interlocking :check
              (every
               (lambda (tr)
                 (every
                  (lambda (sid)
                    (let ((sec (find-if (lambda (s) (string= (getf s :id) sid)) sections)))
                      (and sec (eq (getf sec :state) :occupied))))
                  (getf tr :current-sections)))
               trains))

(definvariant one-train-per-section :on junction-interlocking :check
              (let ((all-sids
                     (mapcan (lambda (tr) (copy-list (getf tr :current-sections))) trains)))
                (= (length all-sids) (length (remove-duplicates all-sids :test #'string=)))))

(definvariant train-authority-valid :on junction-interlocking :check
              (every
               (lambda (tr)
                 (if (not (string= (getf tr :authority-route) ""))
                     (let ((r
                            (find-if (lambda (x) (string= (getf x :id) (getf tr :authority-route)))
                                     routes)))
                       (and r (eq (getf r :state) :set)))
                     t))
               trains))

(definvariant approach-lock-signal-cleared :on junction-interlocking :check
              (every
               (lambda (r)
                 (if (getf r :approach-locked)
                     (let ((sig
                            (find-if (lambda (s) (string= (getf s :id) (getf r :entry-signal)))
                                     signals)))
                       (and sig (not (eq (getf sig :aspect) :danger))))
                     t))
               routes))

(definvariant section-lock-references-valid :on junction-interlocking :check
              (every
               (lambda (sec)
                 (if (not (string= (getf sec :locked-by) ""))
                     (let ((r
                            (find-if (lambda (x) (string= (getf x :id) (getf sec :locked-by)))
                                     routes)))
                       (and r (member (getf r :state) '(:locked :set))))
                     t))
               sections))

(definvariant point-lock-references-valid :on junction-interlocking :check
              (every
               (lambda (p)
                 (if (not (string= (getf p :locked-by) ""))
                     (let ((r
                            (find-if (lambda (x) (string= (getf x :id) (getf p :locked-by)))
                                     routes)))
                       (and r (member (getf r :state) '(:locked :set))))
                     t))
               points))

(definvariant route-entry-signal-exists :on junction-interlocking :check
              (every
               (lambda (r)
                 (some (lambda (s) (string= (getf s :id) (getf r :entry-signal))) signals))
               routes))

(definvariant route-sections-exist :on junction-interlocking :check
              (every
               (lambda (r)
                 (every (lambda (sid) (some (lambda (s) (string= (getf s :id) sid)) sections))
                        (getf r :sections)))
               routes))

(definvariant route-points-exist :on junction-interlocking :check
              (every
               (lambda (r)
                 (every
                  (lambda (pp)
                    (some (lambda (p) (string= (getf p :id) (getf pp :point-id))) points))
                  (getf r :point-positions)))
               routes))

(definvariant flank-set-when-route-set :on junction-interlocking :check
              (every
               (lambda (r)
                 (if (eq (getf r :state) :set)
                     (every
                      (lambda (fp)
                        (let ((p
                               (find-if (lambda (x) (string= (getf x :id) (getf fp :point-id)))
                                        points)))
                          (and p (eq (getf p :position) (getf fp :required-position))
                               (getf p :detected))))
                      (getf r :flank-protections))
                     t))
               routes))

(definvariant no-double-lock :on junction-interlocking :check
              (and
               (let ((locked-secs
                      (remove-if (lambda (s) (string= (getf s :locked-by) "")) sections)))
                 (= (length locked-secs)
                    (length
                     (remove-duplicates (mapcar (lambda (s) (getf s :id)) locked-secs) :test
                                        #'string=))))
               (let ((locked-pts (remove-if (lambda (p) (string= (getf p :locked-by) "")) points)))
                 (= (length locked-pts)
                    (length
                     (remove-duplicates (mapcar (lambda (p) (getf p :id)) locked-pts) :test
                                        #'string=))))))

(definvariant global-point-consistency :on junction-interlocking :check
              (let ((active-routes
                     (remove-if-not (lambda (r) (member (getf r :state) '(:locked :set))) routes)))
                (every
                 (lambda (r1)
                   (every
                    (lambda (r2)
                      (if (string= (getf r1 :id) (getf r2 :id))
                          t
                          (every
                           (lambda (pp1)
                             (every
                              (lambda (pp2)
                                (if (string= (getf pp1 :point-id) (getf pp2 :point-id))
                                    (eq (getf pp1 :required-position)
                                        (getf pp2 :required-position))
                                    t))
                              (getf r2 :point-positions)))
                           (getf r1 :point-positions))))
                    active-routes))
                 active-routes)))

(definvariant authority-covers-train :on junction-interlocking :check
              (every
               (lambda (tr)
                 (if (eq (getf tr :state) :moving)
                     (let ((r
                            (find-if (lambda (x) (string= (getf x :id) (getf tr :authority-route)))
                                     routes)))
                       (if r
                           (every (lambda (sid) (member sid (getf r :sections) :test #'string=))
                                  (getf tr :current-sections))
                           t))
                     t))
               trains))

(defgenerator train
    (overrides)
  (let* ((state
          (or (override-val overrides :state) (nth (random 3) '(:stopped :moving :approaching))))
         (max-speed (or (config :max-approach-speed) 160))
         (speed
          (cond ((eq state :stopped) 0)
                (t (generate-value 'number :min 0.0 :max (coerce max-speed 'single-float)))))
         (heading (or (override-val overrides :heading) (nth (random 2) '(:up :down)))))
    (list :id (or (override-val overrides :id) (generate-value 'string)) :name
          (or (override-val overrides :name) (generate-value 'string)) :state state :speed-kmh
          speed :heading heading :current-sections
          (or (override-val overrides :current-sections) nil) :authority-route
          (or (override-val overrides :authority-route) "") :berth
          (or (override-val overrides :berth) ""))))

(defgenerator point
    (overrides)
  (let* ((pos (or (override-val overrides :position) (nth (random 2) '(:normal :reverse))))
         (locked
          (if (override-present-p overrides :locked)
              (override-val overrides :locked)
              (< (random 4) 1)))
         (failed
          (if (override-present-p overrides :failed)
              (override-val overrides :failed)
              nil))
         (commanded
          (if locked
              pos
              (or (override-val overrides :commanded) pos)))
         (detected
          (if locked
              t
              (if (override-present-p overrides :detected)
                  (override-val overrides :detected)
                  t)))
         (locked-by
          (cond ((override-present-p overrides :locked-by) (override-val overrides :locked-by))
                (locked (generate-value 'string)) (t ""))))
    (list :id (or (override-val overrides :id) (generate-value 'string)) :name
          (or (override-val overrides :name) (generate-value 'string)) :position pos :commanded
          commanded :detected detected :locked locked :locked-by locked-by :failed failed)))

(defgenerator route
    (overrides)
  (let* ((state (or (override-val overrides :state) (nth (random 4) '(:free :free :free :free))))
         (approach-locked
          (if (eq state :set)
              (if (override-present-p overrides :approach-locked)
                  (override-val overrides :approach-locked)
                  nil)
              nil)))
    (list :id (or (override-val overrides :id) (generate-value 'string)) :name
          (or (override-val overrides :name) (generate-value 'string)) :entry-signal
          (or (override-val overrides :entry-signal) (generate-value 'string)) :exit-signal
          (or (override-val overrides :exit-signal) "") :state state :sections
          (or (override-val overrides :sections) (list (generate-value 'string))) :point-positions
          (or (override-val overrides :point-positions) nil) :flank-protections
          (or (override-val overrides :flank-protections) nil) :overlap-sections
          (or (override-val overrides :overlap-sections) nil) :overlap-points
          (or (override-val overrides :overlap-points) nil) :conflicts-with
          (or (override-val overrides :conflicts-with) nil) :approach-locked approach-locked
          :timeout-s (or (override-val overrides :timeout-s) 120))))

(defscenario-generator junction-interlocking
    (overrides)
  (declare (ignore overrides))
  (let* ((num-sections (+ 8 (random 8)))
         (num-points (+ 3 (random 4)))
         (num-signals (+ 4 (random 7)))
         (sections
          (loop for i from 1 to num-sections
                collect (list :id (format nil "TS-~A" i) :name (format nil "~AT" i) :state :clear
                              :length-m (+ 50.0 (random 450.0)) :locked-by "")))
         (points
          (loop for i from 1 to num-points
                collect (list :id (format nil "PT-~A" i) :name (format nil "~A" (+ 100 i))
                              :position :normal :commanded :normal :detected t :locked nil
                              :locked-by "" :failed nil)))
         (signals
          (loop for i from 1 to num-signals
                collect (list :id (format nil "SIG-~A" i) :name (format nil "S~A" i) :aspect
                              :danger :replacement-active nil :approach-locked nil)))
         (num-routes (min (+ 6 (random 7)) (* num-signals 2)))
         (overlap-pool
          (list (getf (nth (- num-sections 1) sections) :id)
                (getf (nth (- num-sections 2) sections) :id)))
         (route-defs
          (loop for i from 1 to num-routes
                for entry-sig = (nth (mod (1- i) num-signals) signals)
                for exit-idx = (mod i num-signals)
                for exit-sig = (nth exit-idx signals)
                for sec-start = (mod (* (1- i) 2) (- num-sections 2))
                for sec-count = (+ 2 (random (min 3 (- (- num-sections 2) sec-start))))
                for route-secs = (loop for j from sec-start below (min (+ sec-start sec-count)
                                                                       (- num-sections 2))
                                       collect (getf (nth j sections) :id))
                for route-pts = (if (and (> num-points 0) (< (random 3) 2))
                                    (let* ((pt-idx (mod (1- i) num-points))
                                           (pt (nth pt-idx points))
                                           (pos
                                            (if (evenp i)
                                                :normal
                                                :reverse)))
                                      (list (list :point-id (getf pt :id) :required-position pos)))
                                    nil)
                for flank-pts = (if (and (> num-points 1) (< (random 3) 1))
                                    (let* ((pt-idx (mod i num-points)) (pt (nth pt-idx points)))
                                      (list
                                       (list :point-id (getf pt :id) :required-position :normal)))
                                    nil)
                for overlap-sec = (list (nth (mod (1- i) 2) overlap-pool))
                collect (list :id (format nil "RT-~A" i) :name
                              (format nil "Route S~A->S~A" (1+ (mod (1- i) num-signals))
                                      (1+ exit-idx))
                              :entry-signal (getf entry-sig :id) :exit-signal (getf exit-sig :id)
                              :state :free :sections route-secs :point-positions route-pts
                              :flank-protections flank-pts :overlap-sections overlap-sec
                              :overlap-points nil :conflicts-with nil :approach-locked nil
                              :timeout-s 120)))
         (routes-with-conflicts
          (loop for r in route-defs
                collect (let ((conflicts
                               (loop for r2 in route-defs
                                     when (and (not (string= (getf r :id) (getf r2 :id)))
                                               (or
                                                (some
                                                 (lambda (s)
                                                   (member s (getf r2 :sections) :test #'string=))
                                                 (getf r :sections))
                                                (let ((all-pp1
                                                       (append (getf r :point-positions)
                                                               (getf r :flank-protections)))
                                                      (all-pp2
                                                       (append (getf r2 :point-positions)
                                                               (getf r2 :flank-protections))))
                                                  (some
                                                   (lambda (pp1)
                                                     (some
                                                      (lambda (pp2)
                                                        (and
                                                         (string= (getf pp1 :point-id)
                                                                  (getf pp2 :point-id))
                                                         (not
                                                          (eq (getf pp1 :required-position)
                                                              (getf pp2 :required-position)))))
                                                      all-pp2))
                                                   all-pp1))))
                                     collect (getf r2 :id))))
                          (setf (getf r :conflicts-with) conflicts)
                          r)))
         (set-routes nil)
         (used-signals nil)
         (used-point-ids nil)
         (remaining (copy-list routes-with-conflicts)))
    (loop for attempt from 0 below (min 2 (length remaining))
          do (let ((candidate
                    (find-if
                     (lambda (r)
                       (and
                        (not
                         (some
                          (lambda (sr)
                            (member (getf r :id) (getf sr :conflicts-with) :test #'string=))
                          set-routes))
                        (not (member (getf r :entry-signal) used-signals :test #'string=))
                        (or (string= (getf r :exit-signal) "")
                            (not (member (getf r :exit-signal) used-signals :test #'string=)))
                        (every
                         (lambda (pp)
                           (not (member (getf pp :point-id) used-point-ids :test #'string=)))
                         (getf r :point-positions))))
                     remaining)))
               (when candidate
                 (push candidate set-routes)
                 (push (getf candidate :entry-signal) used-signals)
                 (when (not (string= (getf candidate :exit-signal) ""))
                   (push (getf candidate :exit-signal) used-signals))
                 (dolist (pp (getf candidate :point-positions))
                   (push (getf pp :point-id) used-point-ids))
                 (setf remaining (remove candidate remaining)))))
    (dolist (r set-routes)
      (setf (getf r :state) :set)
      (dolist (sid (getf r :sections))
        (let ((sec (find-if (lambda (s) (string= (getf s :id) sid)) sections)))
          (when sec (setf (getf sec :locked-by) (getf r :id)))))
      (dolist (pp (getf r :point-positions))
        (let ((pt (find-if (lambda (p) (string= (getf p :id) (getf pp :point-id))) points)))
          (when pt
            (setf (getf pt :position) (getf pp :required-position))
            (setf (getf pt :commanded) (getf pp :required-position))
            (setf (getf pt :detected) t)
            (setf (getf pt :locked) t)
            (setf (getf pt :locked-by) (getf r :id)))))
      (dolist (fp (getf r :flank-protections))
        (let ((pt (find-if (lambda (p) (string= (getf p :id) (getf fp :point-id))) points)))
          (when pt
            (setf (getf pt :position) (getf fp :required-position))
            (setf (getf pt :commanded) (getf fp :required-position))
            (setf (getf pt :detected) t)))))
    (dolist (r set-routes)
      (let ((entry-sig
             (find-if (lambda (s) (string= (getf s :id) (getf r :entry-signal))) signals)))
        (when entry-sig (setf (getf entry-sig :aspect) :caution))))
    (let ((trains nil))
      (let ((all-overlap-secs
             (mapcan (lambda (sr) (copy-list (getf sr :overlap-sections))) set-routes)))
        (dolist (r set-routes)
          (when (< (random 3) 2)
            (let* ((route-secs (getf r :sections))
                   (safe-secs
                    (remove-if (lambda (sid) (member sid all-overlap-secs :test #'string=))
                               route-secs))
                   (pick-sec
                    (if safe-secs
                        (first safe-secs)
                        nil)))
              (when pick-sec
                (let ((train-sec (list pick-sec))
                      (train-id (format nil "TR-~A" (1+ (length trains)))))
                  (let ((sec (find-if (lambda (s) (string= (getf s :id) pick-sec)) sections)))
                    (when sec (setf (getf sec :state) :occupied)))
                  (push
                   (list :id train-id :name (format nil "~AA~A" (1+ (random 9)) (+ 10 (random 90)))
                         :state :stopped :speed-kmh 0 :heading (nth (random 2) '(:up :down))
                         :current-sections train-sec :authority-route (getf r :id) :berth
                         (getf r :entry-signal))
                   trains)))))))
      (when (null trains)
        (push
         (list :id "TR-1" :name "1A01" :state :stopped :speed-kmh 0 :heading :up :current-sections
               nil :authority-route "" :berth "")
         trains))
      (let ((final-routes
             (append set-routes
                     (remove-if (lambda (r) (member r set-routes)) routes-with-conflicts))))
        (list :sections sections :points points :signals signals :routes final-routes :trains
              trains)))))

(defscenario-negative-generator junction-interlocking
    (overrides)
  (declare (ignore overrides))
  (let* ((sections
          (loop for i from 1 to 10
                collect (list :id (format nil "TS-~A" i) :name (format nil "~AT" i) :state :clear
                              :length-m (+ 100.0 (random 200.0)) :locked-by "")))
         (points
          (loop for i from 1 to 4
                collect (list :id (format nil "PT-~A" i) :name (format nil "~A" (+ 100 i))
                              :position :normal :commanded :normal :detected t :locked nil
                              :locked-by "" :failed nil)))
         (signals
          (loop for i from 1 to 6
                collect (list :id (format nil "SIG-~A" i) :name (format nil "S~A" i) :aspect
                              :danger :replacement-active nil :approach-locked nil)))
         (shared-secs (list "TS-1" "TS-2" "TS-3"))
         (r1
          (list :id "RT-1" :name "Route 1" :entry-signal "SIG-1" :exit-signal "SIG-2" :state :set
                :sections shared-secs :point-positions
                (list (list :point-id "PT-1" :required-position :normal)) :flank-protections nil
                :overlap-sections (list "TS-4") :overlap-points nil :conflicts-with (list "RT-2")
                :approach-locked nil :timeout-s 120))
         (r2
          (list :id "RT-2" :name "Route 2" :entry-signal "SIG-3" :exit-signal "SIG-4" :state :set
                :sections shared-secs :point-positions
                (list (list :point-id "PT-1" :required-position :reverse)) :flank-protections nil
                :overlap-sections (list "TS-5") :overlap-points nil :conflicts-with (list "RT-1")
                :approach-locked nil :timeout-s 120))
         (routes
          (list r1 r2
                (list :id "RT-3" :name "Route 3" :entry-signal "SIG-5" :exit-signal "SIG-6" :state
                      :free :sections (list "TS-6" "TS-7") :point-positions nil :flank-protections
                      nil :overlap-sections nil :overlap-points nil :conflicts-with nil
                      :approach-locked nil :timeout-s 120)
                (list :id "RT-4" :name "Route 4" :entry-signal "SIG-6" :exit-signal "SIG-5" :state
                      :free :sections (list "TS-8" "TS-9") :point-positions nil :flank-protections
                      nil :overlap-sections nil :overlap-points nil :conflicts-with nil
                      :approach-locked nil :timeout-s 120)
                (list :id "RT-5" :name "Route 5" :entry-signal "SIG-2" :exit-signal "SIG-3" :state
                      :free :sections (list "TS-4" "TS-5") :point-positions nil :flank-protections
                      nil :overlap-sections nil :overlap-points nil :conflicts-with nil
                      :approach-locked nil :timeout-s 120)
                (list :id "RT-6" :name "Route 6" :entry-signal "SIG-4" :exit-signal "SIG-1" :state
                      :free :sections (list "TS-9" "TS-10") :point-positions nil :flank-protections
                      nil :overlap-sections nil :overlap-points nil :conflicts-with nil
                      :approach-locked nil :timeout-s 120)))
         (trains
          (list
           (list :id "TR-1" :name "2B34" :state :stopped :speed-kmh 0 :heading :up
                 :current-sections nil :authority-route "" :berth ""))))
    (list :sections sections :points points :signals signals :routes routes :trains trains)))


;;;; src/spec/helpers.lisp
;;;;
;;;; Standalone utility functions for use in invariant check forms.
;;;; Pure math — no spec dependencies.

(defpackage #:mcp-lisp/src/spec/helpers
  (:use #:cl)
  (:export #:all-pairs-check
           #:consecutive-pairs-check
           #:distribute-values
           #:partition-into
           #:haversine-distance-nm
           #:initial-bearing-deg
           #:heading-difference-deg
           #:point-in-polygon-p
           #:intervals-overlap-p
           #:interval-contains-p
           #:interval-before-p
           #:elapsed-since
           #:duration-at-least-p
           #:within-retention-period-p))

(in-package #:mcp-lisp/src/spec/helpers)

;;; ---------------------------------------------------------------------------
;;; Collection predicates
;;; ---------------------------------------------------------------------------

(defun all-pairs-check (lst pred)
  "Check that PRED holds for every unordered pair in LST."
  (loop for (a . rest) on lst
        always (every (lambda (b) (funcall pred a b)) rest)))

(defun consecutive-pairs-check (lst pred)
  "Check that PRED holds for every consecutive pair in LST."
  (loop for (a b) on lst
        while b
        always (funcall pred a b)))

;;; ---------------------------------------------------------------------------
;;; Haversine
;;; ---------------------------------------------------------------------------

(declaim (ftype (function (real real real real) double-float) haversine-distance-nm))
(defun haversine-distance-nm (lat1 lon1 lat2 lon2)
  "Great-circle distance between two lat/lon points, in nautical miles."
  (declare (optimize (speed 3) (safety 1)))
  (let* ((to-rad (load-time-value (/ pi 180.0d0) t))
         (rlat1 (* (coerce lat1 'double-float) to-rad))
         (rlat2 (* (coerce lat2 'double-float) to-rad))
         (dlat (- rlat2 rlat1))
         (dlon (* (- (coerce lon2 'double-float) (coerce lon1 'double-float)) to-rad)))
    (declare (type double-float to-rad rlat1 rlat2 dlat dlon))
    (let* ((sdlat2 (sin (the double-float (/ dlat 2.0d0))))
           (sdlon2 (sin (the double-float (/ dlon 2.0d0))))
           (a (+ (* sdlat2 sdlat2)
                  (* (cos rlat1) (cos rlat2) sdlon2 sdlon2)))
           (c (* 2.0d0 (asin (sqrt (the (double-float 0.0d0 1.0d0) a))))))
      (declare (type double-float sdlat2 sdlon2 a c))
      (* 3440.065d0 c))))

;;; ---------------------------------------------------------------------------
;;; Bearing & heading
;;; ---------------------------------------------------------------------------

(declaim (ftype (function (real real real real) double-float) initial-bearing-deg))
(defun initial-bearing-deg (lat1 lon1 lat2 lon2)
  "Forward azimuth (initial bearing) from point 1 to point 2, in degrees [0,360)."
  (declare (optimize (speed 3) (safety 1)))
  (let* ((to-rad (load-time-value (/ pi 180.0d0) t))
         (to-deg (load-time-value (/ 180.0d0 pi) t))
         (rlat1 (* (coerce lat1 'double-float) to-rad))
         (rlat2 (* (coerce lat2 'double-float) to-rad))
         (dlon  (* (- (coerce lon2 'double-float) (coerce lon1 'double-float)) to-rad))
         (x (- (* (cos rlat1) (sin rlat2))
               (* (sin rlat1) (cos rlat2) (cos dlon))))
         (y (* (sin dlon) (cos rlat2)))
         (theta (atan y x)))
    (declare (type double-float to-rad to-deg rlat1 rlat2 dlon x y theta))
    (mod (* theta to-deg) 360.0d0)))

(declaim (ftype (function (real real) double-float) heading-difference-deg))
(defun heading-difference-deg (h1 h2)
  "Smallest angular difference between two headings in degrees [0,180]."
  (let ((d (abs (- (mod (coerce h1 'double-float) 360.0d0)
                   (mod (coerce h2 'double-float) 360.0d0)))))
    (if (> d 180.0d0) (- 360.0d0 d) d)))

;;; ---------------------------------------------------------------------------
;;; Point-in-polygon (ray casting)
;;; ---------------------------------------------------------------------------

(defun point-in-polygon-p (lat lon polygon)
  "Return T if (LAT, LON) is inside POLYGON.
POLYGON is a list of (lat lon) pairs forming a closed ring (last edge wraps to
first vertex automatically). Uses the ray-casting algorithm on the lat/lon
plane — accurate at TRACON scale (~60 NM)."
  (let ((inside nil)
        (n (length polygon)))
    (loop for i from 0 below n
          for (yi xi) = (nth i polygon)
          for (yj xj) = (nth (mod (1+ i) n) polygon)
          when (and (not (eq (> yi lat) (> yj lat)))
                    (< lon (+ xi (/ (* (- xj xi) (- lat yi))
                                    (- yj yi)))))
            do (setf inside (not inside)))
    inside))

;;; ---------------------------------------------------------------------------
;;; Temporal interval helpers
;;; ---------------------------------------------------------------------------

(defun intervals-overlap-p (start1 dur1 start2 dur2)
  "Return T if two intervals [start1, start1+dur1) and [start2, start2+dur2) overlap."
  (and (< start1 (+ start2 dur2))
       (< start2 (+ start1 dur1))))

(defun interval-contains-p (outer-start outer-dur inner-start inner-dur)
  "Return T if [inner-start, inner-start+inner-dur) is entirely within [outer-start, outer-start+outer-dur)."
  (and (<= outer-start inner-start)
       (<= (+ inner-start inner-dur) (+ outer-start outer-dur))))

(defun interval-before-p (start1 dur1 start2)
  "Return T if interval [start1, start1+dur1) ends at or before START2."
  (<= (+ start1 dur1) start2))

;;; ---------------------------------------------------------------------------
;;; Temporal duration helpers
;;; ---------------------------------------------------------------------------

(defun elapsed-since (timestamp now)
  "Return the elapsed time between TIMESTAMP and NOW."
  (- now timestamp))

(defun duration-at-least-p (timestamp now min-duration)
  "Return T if at least MIN-DURATION has elapsed between TIMESTAMP and NOW."
  (>= (- now timestamp) min-duration))

(defun within-retention-period-p (event-time retention-duration now)
  "Return T if NOW is still within RETENTION-DURATION of EVENT-TIME.
I.e. (- now event-time) < retention-duration."
  (< (- now event-time) retention-duration))

;;; ---------------------------------------------------------------------------
;;; Generation strategies for cross-entity constraints
;;; ---------------------------------------------------------------------------

(defun distribute-values (n total &key (min 0))
  "Generate N non-negative numbers that sum to at most TOTAL, each >= MIN.
Useful in scenario generators: distribute child demands within parent capacity."
  (let* ((remaining (- total (* n min)))
         (result nil))
    (when (< remaining 0) (setf remaining 0))
    (dotimes (i n)
      (let ((share (if (= i (1- n))
                       remaining
                       (random (1+ (floor remaining (max 1 (- n i))))))))
        (push (+ min share) result)
        (decf remaining share)))
    (nreverse result)))

(defun partition-into (items n)
  "Randomly partition ITEMS into N non-empty groups (when possible).
Returns a list of N lists. Useful for assigning children to parents."
  (let ((groups (make-array n :initial-element nil))
        (shuffled (let ((v (coerce (copy-list items) 'vector)))
                    (loop for i from (1- (length v)) downto 1
                          for j = (random (1+ i))
                          do (rotatef (aref v i) (aref v j)))
                    (coerce v 'list))))
    (loop for item in shuffled
          for i from 0
          do (push item (aref groups (mod i n))))
    (coerce groups 'list)))

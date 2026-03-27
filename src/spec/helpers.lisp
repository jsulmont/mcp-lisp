;;;; src/spec/helpers.lisp
;;;;
;;;; Standalone utility functions for use in invariant check forms.
;;;; Pure math — no spec dependencies.

(defpackage #:mcp-lisp/src/spec/helpers
  (:use #:cl)
  (:export #:all-pairs-check
           #:consecutive-pairs-check
           #:haversine-distance-nm
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

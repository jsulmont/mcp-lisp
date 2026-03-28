(mcp-lisp/src/spec/serialization::defentity room nil (id string :required t :unique t)
 (name string :required t) (capacity integer :required t :min 1 :max 200)
 (has-projector boolean :default nil) (has-video-conf boolean :default nil)
 (:has-many bookings :of booking))

(mcp-lisp/src/spec/serialization::defentity booking nil (id string :required t :unique t)
 (title string :required t) (organizer string :required t) (start-time integer :required t :min 0)
 (duration-minutes integer :required t :min 15 :max 480)
 (attendee-count integer :required t :min 1) (needs-projector boolean :default nil)
 (needs-video-conf boolean :default nil)
 (status (member :tentative :confirmed :cancelled) :default :tentative) (:belongs-to room))

(mcp-lisp/src/spec/serialization::defrule confirm-booking :when (booking :status :tentative)
 :ensures ((eq (booking-status booking) :confirmed)))

(mcp-lisp/src/spec/serialization::defrule cancel-booking :when
 (booking :status (member :tentative :confirmed)) :ensures
 ((eq (booking-status booking) :cancelled)))

(mcp-lisp/src/spec/serialization::definvariant valid-duration :on booking :check
 (and (>= (booking-duration-minutes booking) 15) (<= (booking-duration-minutes booking) 480)))

(mcp-lisp/src/spec/serialization::definvariant positive-attendees :on booking :check
 (>= (booking-attendee-count booking) 1))

(mcp-lisp/src/spec/serialization::defscenario room-bookings :entities
 ((room 1 room) (bookings (2 10) booking :per room :refs ((room-id :from room :field id)))))

(mcp-lisp/src/spec/serialization::definvariant attendees-within-capacity :on room-bookings :check
 (let ((cap (room-capacity room)))
   (every (lambda (b) (<= (booking-attendee-count b) cap)) bookings)))

(mcp-lisp/src/spec/serialization::definvariant equipment-projector-available :on room-bookings
 :check
 (every (lambda (b) (or (not (booking-needs-projector b)) (room-has-projector room))) bookings))

(mcp-lisp/src/spec/serialization::definvariant equipment-video-conf-available :on room-bookings
 :check
 (every (lambda (b) (or (not (booking-needs-video-conf b)) (room-has-video-conf room))) bookings))

(mcp-lisp/src/spec/serialization::definvariant no-overlap-non-cancelled :on room-bookings :check
 (let ((active (remove-if (lambda (b) (eq (booking-status b) :cancelled)) bookings)))
   (all-pairs-check active
                    (lambda (a b)
                      (not
                       (intervals-overlap-p (booking-start-time a) (booking-duration-minutes a)
                                            (booking-start-time b)
                                            (booking-duration-minutes b)))))))

(defscenario-generator room-bookings
    (overrides)
  (declare (ignore overrides))
  (let* ((room (generate-instance "room"))
         (cap (getf room :capacity))
         (has-proj (getf room :has-projector))
         (has-vc (getf room :has-video-conf))
         (n-bookings (+ 2 (random 9)))
         (slot-duration 60)
         (bookings
          (loop for i below n-bookings
                for start = (* i slot-duration)
                for dur = (+ 15 (random 46))
                collect (generate-instance "booking"
                                           (list :room-id (getf room :id) :start-time start
                                                 :duration-minutes dur :attendee-count
                                                 (+ 1 (random cap)) :needs-projector
                                                 (and has-proj (zerop (random 2)))
                                                 :needs-video-conf
                                                 (and has-vc (zerop (random 2))))))))
    (list :room room :bookings bookings)))

(defscenario-negative-generator room-bookings
    (overrides)
  (declare (ignore overrides))
  (let* ((room
          (generate-instance "room" (list :capacity 5 :has-projector nil :has-video-conf nil)))
         (violation (random 3))
         (bookings
          (cond
           ((= violation 0)
            (list
             (generate-instance "booking"
                                (list :room-id (getf room :id) :attendee-count 10 :start-time 0
                                      :duration-minutes 30 :needs-projector nil :needs-video-conf
                                      nil))))
           ((= violation 1)
            (list
             (generate-instance "booking"
                                (list :room-id (getf room :id) :attendee-count 2 :start-time 0
                                      :duration-minutes 30 :needs-projector t :needs-video-conf
                                      nil))))
           (t
            (list
             (generate-instance "booking"
                                (list :room-id (getf room :id) :attendee-count 2 :start-time 0
                                      :duration-minutes 60 :status :confirmed :needs-projector nil
                                      :needs-video-conf nil))
             (generate-instance "booking"
                                (list :room-id (getf room :id) :attendee-count 2 :start-time 30
                                      :duration-minutes 60 :status :tentative :needs-projector nil
                                      :needs-video-conf nil)))))))
    (list :room room :bookings bookings)))


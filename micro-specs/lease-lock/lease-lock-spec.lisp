(mcp-lisp/src/spec/serialization::defentity node nil (id string :required t :unique t)
 (state (member :idle :requesting :holding :expired) :default :idle) (:belongs-to lease))

(mcp-lisp/src/spec/serialization::defentity lease nil (id string :required t :unique t)
 (holder-id string :nullable t) (grant-time integer :nullable t :min 0)
 (duration integer :required t :min 1 :max 300) (:has-many nodes :of node))

(mcp-lisp/src/spec/serialization::defrule request-lease :when (node :state :idle) :ensures
 ((eq (node-state node) :requesting)))

(mcp-lisp/src/spec/serialization::defrule grant-lease :when (node :state :requesting) :sets
 ((node-state node) :holding (lease-holder-id lease) (node-id node) (lease-grant-time lease)
  (get-universal-time))
 :ensures ((eq (node-state node) :holding)))

(mcp-lisp/src/spec/serialization::defrule expire-lease :when (node :state :holding) :sets
 ((node-state node) :expired (lease-holder-id lease) nil (lease-grant-time lease) nil) :ensures
 ((eq (node-state node) :expired)))

(mcp-lisp/src/spec/serialization::defrule reset-node :when (node :state :expired) :ensures
 ((eq (node-state node) :idle)))

(mcp-lisp/src/spec/serialization::definvariant positive-duration :on lease :check
 (>= (lease-duration lease) 1))

(mcp-lisp/src/spec/serialization::definvariant grant-time-when-held :on lease :check
 (if (lease-holder-id lease)
     (and (lease-grant-time lease) (> (lease-grant-time lease) 0))
     t))

(mcp-lisp/src/spec/serialization::definvariant no-grant-time-when-free :on lease :check
 (if (null (lease-holder-id lease))
     (null (lease-grant-time lease))
     t))

(mcp-lisp/src/spec/serialization::defscenario lease-cluster :entities
 ((the-lease 1 lease) (nodes (2 5) node :per the-lease)))

(mcp-lisp/src/spec/serialization::definvariant mutual-exclusion :on lease-cluster :check
 (let ((holders (remove-if-not (lambda (n) (eq (getf n :state) :holding)) nodes)))
   (<= (length holders) 1)))

(mcp-lisp/src/spec/serialization::definvariant holder-agreement :on lease-cluster :check
 (let ((holder-id (getf the-lease :holder-id)))
   (if holder-id
       (let ((holder-node (find holder-id nodes :key (lambda (n) (getf n :id)) :test #'equal)))
         (and holder-node (eq (getf holder-node :state) :holding)))
       t)))

(mcp-lisp/src/spec/serialization::definvariant holding-implies-lease :on lease-cluster :check
 (let ((holding-nodes (remove-if-not (lambda (n) (eq (getf n :state) :holding)) nodes)))
   (if holding-nodes
       (equal (getf (first holding-nodes) :id) (getf the-lease :holder-id))
       t)))

(defgenerator lease
    (overrides)
  (let* ((inst (default-generate-instance "lease" overrides)) (holder (getf inst :holder-id)))
    (if holder
        (progn
         (unless (getf inst :grant-time) (setf (getf inst :grant-time) (+ 1 (random 1000000))))
         inst)
        (progn (setf (getf inst :grant-time) nil) inst))))

(defscenario-generator lease-cluster
    (overrides)
  (declare (ignore overrides))
  (let* ((n-nodes (+ 2 (random 4)))
         (hold-p (< (random 100) 40))
         (the-lease (generate-instance "lease" (list :holder-id nil :grant-time nil)))
         (nodes
          (loop for i from 1 to n-nodes
                collect (generate-instance "node" (list :state :idle)))))
    (when hold-p
      (let* ((chosen (nth (random (length nodes)) nodes)) (chosen-id (getf chosen :id)))
        (setf (getf chosen :state) :holding)
        (setf (getf the-lease :holder-id) chosen-id)
        (setf (getf the-lease :grant-time) (+ 1 (random 1000000)))))
    (list :the-lease the-lease :nodes nodes)))

(defscenario-negative-generator lease-cluster
    (overrides)
  (declare (ignore overrides))
  (let* ((n-nodes (+ 2 (random 4)))
         (the-lease (generate-instance "lease" (list :holder-id nil :grant-time nil)))
         (nodes
          (loop for i from 1 to n-nodes
                collect (generate-instance "node" (list :state :idle))))
         (violation (random 3)))
    (cond
     ((= violation 0)
      (let ((n1 (nth 0 nodes)) (n2 (nth 1 nodes)))
        (setf (getf n1 :state) :holding)
        (setf (getf n2 :state) :holding)
        (setf (getf the-lease :holder-id) (getf n1 :id))
        (setf (getf the-lease :grant-time) (+ 1 (random 1000000)))))
     ((= violation 1) (setf (getf the-lease :holder-id) "phantom-node")
      (setf (getf the-lease :grant-time) (+ 1 (random 1000000)))))
    ((= violation 2)
     (let ((n1 (nth 0 nodes)))
       (setf (getf n1 :state) :holding)))
    (list :the-lease the-lease :nodes nodes)))


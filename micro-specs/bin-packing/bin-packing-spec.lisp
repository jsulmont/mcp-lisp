(mcp-lisp/src/spec/serialization::defentity bin nil (id string :required t :unique t)
 (weight-capacity number :required t :min 1.0 :max 1000.0)
 (volume-capacity number :required t :min 1.0 :max 1000.0)
 (max-item-count integer :required t :min 1 :max 100)
 (status (member :open :sealed) :default :open) (:has-many items :of item))

(mcp-lisp/src/spec/serialization::defentity item nil (id string :required t :unique t)
 (weight number :required t :min 0.1 :max 200.0) (volume number :required t :min 0.1 :max 200.0)
 (category (member :fragile :hazardous :standard) :required t) (:belongs-to bin))

(mcp-lisp/src/spec/serialization::defrule seal-bin :when (bin :status :open) :ensures
 ((eq (bin-status bin) :sealed)))

(mcp-lisp/src/spec/serialization::defrule assign-item :when (bin :status :open) :requires
 ((< (length (bin-items bin)) (bin-max-item-count bin))) :ensures ((eq (bin-status bin) :open)))

(mcp-lisp/src/spec/serialization::definvariant positive-weight-capacity :on bin :check
 (> (bin-weight-capacity bin) 0))

(mcp-lisp/src/spec/serialization::definvariant positive-volume-capacity :on bin :check
 (> (bin-volume-capacity bin) 0))

(mcp-lisp/src/spec/serialization::definvariant positive-max-item-count :on bin :check
 (> (bin-max-item-count bin) 0))

(mcp-lisp/src/spec/serialization::definvariant valid-bin-status :on bin :check
 (member (bin-status bin) '(:open :sealed)))

(mcp-lisp/src/spec/serialization::definvariant positive-item-weight :on item :check
 (> (item-weight item) 0))

(mcp-lisp/src/spec/serialization::definvariant positive-item-volume :on item :check
 (> (item-volume item) 0))

(mcp-lisp/src/spec/serialization::definvariant valid-item-category :on item :check
 (member (item-category item) '(:fragile :hazardous :standard)))

(mcp-lisp/src/spec/serialization::defscenario bin-packing :entities
 ((bins (1 5) bin) (items (1 20) item :per bins)))

(mcp-lisp/src/spec/serialization::definvariant weight-within-capacity :on bin-packing :check
 (every
  (lambda (b)
    (let ((bin-items (getf b :items)))
      (<= (reduce #'+ bin-items :key (lambda (i) (getf i :weight)) :initial-value 0)
          (getf b :weight-capacity))))
  bins))

(mcp-lisp/src/spec/serialization::definvariant volume-within-capacity :on bin-packing :check
 (every
  (lambda (b)
    (let ((bin-items (getf b :items)))
      (<= (reduce #'+ bin-items :key (lambda (i) (getf i :volume)) :initial-value 0)
          (getf b :volume-capacity))))
  bins))

(mcp-lisp/src/spec/serialization::definvariant item-count-within-limit :on bin-packing :check
 (every (lambda (b) (<= (length (getf b :items)) (getf b :max-item-count))) bins))

(mcp-lisp/src/spec/serialization::definvariant no-hazardous-with-fragile :on bin-packing :check
 (every
  (lambda (b)
    (let* ((bin-items (getf b :items))
           (categories (mapcar (lambda (i) (getf i :category)) bin-items)))
      (not (and (member :hazardous categories) (member :fragile categories)))))
  bins))

(defscenario-generator bin-packing
    (overrides)
  (declare (ignore overrides))
  (let* ((num-bins (+ 1 (random 5)))
         (bins
          (loop repeat num-bins
                collect (generate-instance "bin"))))
    (dolist (b bins)
      (let* ((cap-w (getf b :weight-capacity))
             (cap-v (getf b :volume-capacity))
             (max-n (getf b :max-item-count))
             (num-items (+ 1 (random (min max-n 5))))
             (categories (list :fragile :hazardous :standard))
             (allowed-cat
              (let ((pick (nth (random 3) categories)))
                (if (eq pick :standard)
                    categories
                    (remove
                     (if (eq pick :fragile)
                         :hazardous
                         :fragile)
                     categories))))
             (remaining-w cap-w)
             (remaining-v cap-v)
             (items nil))
        (dotimes (i num-items)
          (when (and (> remaining-w 0.1) (> remaining-v 0.1))
            (let* ((max-w (min remaining-w 200.0))
                   (max-v (min remaining-v 200.0))
                   (w (+ 0.1 (* (random 1.0) (- (min max-w (/ cap-w num-items 0.5)) 0.1))))
                   (v (+ 0.1 (* (random 1.0) (- (min max-v (/ cap-v num-items 0.5)) 0.1))))
                   (cat (nth (random (length allowed-cat)) allowed-cat))
                   (item (generate-instance "item" (list :weight w :volume v :category cat))))
              (push item items)
              (decf remaining-w w)
              (decf remaining-v v))))
        (setf (getf b :items) (nreverse items))))
    (list :bins bins :items nil)))

(defscenario-negative-generator bin-packing
    (overrides)
  (declare (ignore overrides))
  (let* ((bin (generate-instance "bin")) (violation (random 4)))
    (cond
     ((= violation 0)
      (let* ((cap (getf bin :weight-capacity))
             (items
              (loop repeat 3
                    collect (generate-instance "item"
                                               (list :weight (* cap 0.5) :category :standard)))))
        (setf (getf bin :items) items)
        (list :bins (list bin) :items nil)))
     ((= violation 1)
      (let* ((cap (getf bin :volume-capacity))
             (items
              (loop repeat 3
                    collect (generate-instance "item"
                                               (list :volume (* cap 0.5) :category :standard)))))
        (setf (getf bin :items) items)
        (list :bins (list bin) :items nil)))
     ((= violation 2)
      (let* ((max-n (getf bin :max-item-count))
             (items
              (loop repeat (+ max-n 1)
                    collect (generate-instance "item"
                                               (list :weight 0.1 :volume 0.1 :category
                                                     :standard)))))
        (setf (getf bin :items) items)
        (list :bins (list bin) :items nil)))
     (t
      (let* ((items
              (list (generate-instance "item" (list :category :hazardous :weight 0.1 :volume 0.1))
                    (generate-instance "item" (list :category :fragile :weight 0.1 :volume 0.1)))))
        (setf (getf bin :items) items)
        (list :bins (list bin) :items nil))))))

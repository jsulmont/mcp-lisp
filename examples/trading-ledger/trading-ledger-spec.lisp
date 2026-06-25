(clear-specs)

(defentity trader ()
  (id string :required t :unique t)
  (name string :required t)
  (tier (member :retail :professional :market-maker) :default :retail)
  (margin-ratio number :default 1.0)
  (suspended boolean :default nil)
  (:has-many positions :of position)
  (:has-many orders :of order))

(defentity position ()
  (id string :required t :unique t)
  (instrument string :required t)
  (quantity number :required t)
  (entry-price number :required t)
  (notional number :required t)
  (side (member :long :short) :required t))

(defentity order ()
  (id string :required t :unique t)
  (instrument string :required t)
  (side (member :buy :sell) :required t)
  (quantity number :required t)
  (price number :required t)
  (state (member :pending :validated :filled :rejected :cancelled) :default :pending)
  (fill-price number :default 0)
  (slippage number :default 0))

(defentity risk-limit ()
  (id string :required t :unique t)
  (max-notional number :required t)
  (max-position-count integer :required t)
  (max-single-order number :required t)
  (max-slippage-pct number :default 5.0))

(defrule validate-order
  :when (order :state :pending)
  :requires (t)
  :ensures ((eq (order-state order) :validated)))

(defrule fill-order
  :when (order :state :validated)
  :requires (t)
  :ensures ((eq (order-state order) :filled)))

(defrule reject-order
  :when (order :state :pending)
  :requires (t)
  :ensures ((eq (order-state order) :rejected)))

(defrule cancel-order
  :when (order :state :pending)
  :requires (t)
  :ensures ((eq (order-state order) :cancelled)))

(defrule cancel-validated-order
  :when (order :state :validated)
  :requires (t)
  :ensures ((eq (order-state order) :cancelled)))

(defrule suspend-trader
  :when (trader :suspended nil)
  :requires ((< (trader-margin-ratio trader) 0.5))
  :ensures ((eq (trader-suspended trader) t)))

(definvariant order-positive-values
  :on order
  :check (if (not (member (order-state order) '(:rejected :cancelled)))
             (and (> (order-quantity order) 0)
                  (> (order-price order) 0))
             t))

(definvariant fill-price-consistency
  :on order
  :check (if (eq (order-state order) :filled)
             (> (order-fill-price order) 0)
             (= (order-fill-price order) 0)))

(definvariant non-negative-slippage
  :on order
  :check (>= (order-slippage order) 0))

(definvariant position-notional-correct
  :on position
  :check (= (position-notional position)
             (* (position-quantity position) (position-entry-price position))))

(definvariant no-negative-margin
  :on trader
  :check (>= (trader-margin-ratio trader) 0))

(definvariant suspended-means-low-margin
  :on trader
  :check (if (trader-suspended trader)
             (< (trader-margin-ratio trader) 0.5)
             t))

(definvariant risk-limit-sane
  :on risk-limit
  :check (and (> (risk-limit-max-notional risk-limit) 0)
              (> (risk-limit-max-position-count risk-limit) 0)
              (> (risk-limit-max-single-order risk-limit) 0)
              (>= (risk-limit-max-slippage-pct risk-limit) 0)
              (<= (risk-limit-max-slippage-pct risk-limit) 100)))

(defgenerator position (overrides)
  (let* ((quantity (or (cdr (assoc :quantity overrides))
                       (generate-value 'number :min 0.01 :max 1000.0)))
         (entry-price (or (cdr (assoc :entry-price overrides))
                          (generate-value 'number :min 0.01 :max 10000.0)))
         (notional (* quantity entry-price)))
    (list :id (generate-value 'string)
          :instrument (generate-value 'string)
          :quantity quantity
          :entry-price entry-price
          :notional notional
          :side (generate-value '(member :long :short)))))

(defgenerator order (overrides)
  (let* ((state (or (cdr (assoc :state overrides))
                    (generate-value '(member :pending :validated :filled :rejected :cancelled))))
         (filled-p (eq state :filled))
         (quantity (generate-value 'number :min 0.01 :max 1000.0))
         (price (generate-value 'number :min 0.01 :max 10000.0))
         (fill-price (if filled-p
                         (generate-value 'number :min 0.01 :max 10000.0)
                         0))
         (slippage (generate-value 'number :min 0.0 :max 100.0)))
    (list :id (generate-value 'string)
          :instrument (generate-value 'string)
          :side (generate-value '(member :buy :sell))
          :quantity quantity
          :price price
          :state state
          :fill-price fill-price
          :slippage slippage)))

(defgenerator trader (overrides)
  (let* ((suspended (or (cdr (assoc :suspended overrides))
                        (generate-value 'boolean)))
         (margin-ratio (if suspended
                           (generate-value 'number :min 0.0 :max 0.4999)
                           (generate-value 'number :min 0.0 :max 10.0))))
    (list :id (generate-value 'string)
          :name (generate-value 'string)
          :tier (generate-value '(member :retail :professional :market-maker))
          :margin-ratio margin-ratio
          :suspended suspended)))

(mcp-lisp/src/spec/serialization::defentity node nil (id string :required t :unique t)
 (role (member :requester :responder) :required t :immutable t)
 (status (member :idle :waiting :processing :accepted :rejected) :default :idle))

(mcp-lisp/src/spec/serialization::defentity message nil (id string :required t :unique t)
 (msg-type (member :request :response) :required t :immutable t)
 (sender-id string :required t :immutable t) (receiver-id string :required t :immutable t)
 (payload integer :required t :immutable t :min 0 :max 100)
 (response-result (member :accept :reject) :nullable t :immutable t)
 (delivery-status (member :pending :delivered) :default :pending))

(mcp-lisp/src/spec/serialization::defconfig (threshold integer :default 50 :min 1 :max 100))

(mcp-lisp/src/spec/serialization::defrule send-request :when (node :status :idle) :requires
 ((eq (node-role node) :requester)) :ensures ((eq (node-status node) :waiting)))

(mcp-lisp/src/spec/serialization::defrule deliver-request :when (node :status :idle) :requires
 ((eq (node-role node) :responder)) :ensures ((eq (node-status node) :processing)))

(mcp-lisp/src/spec/serialization::defrule respond-accept :when (node :status :processing) :requires
 ((eq (node-role node) :responder)) :ensures ((eq (node-status node) :idle)))

(mcp-lisp/src/spec/serialization::defrule respond-reject :when (node :status :processing) :requires
 ((eq (node-role node) :responder)) :ensures ((eq (node-status node) :idle)))

(mcp-lisp/src/spec/serialization::defrule deliver-accept :when (node :status :waiting) :requires
 ((eq (node-role node) :requester)) :ensures ((eq (node-status node) :accepted)))

(mcp-lisp/src/spec/serialization::defrule deliver-reject :when (node :status :waiting) :requires
 ((eq (node-role node) :requester)) :ensures ((eq (node-status node) :rejected)))

(mcp-lisp/src/spec/serialization::defrule deliver-message :when (message :delivery-status :pending)
 :ensures ((eq (message-delivery-status message) :delivered)))

(mcp-lisp/src/spec/serialization::definvariant requester-valid-states :on node :check
 (if (eq (node-role node) :requester)
     (member (node-status node) '(:idle :waiting :accepted :rejected))
     t))

(mcp-lisp/src/spec/serialization::definvariant responder-valid-states :on node :check
 (if (eq (node-role node) :responder)
     (member (node-status node) '(:idle :processing))
     t))

(mcp-lisp/src/spec/serialization::definvariant request-no-result :on message :check
 (if (eq (message-msg-type message) :request)
     (null (message-response-result message))
     t))

(mcp-lisp/src/spec/serialization::definvariant response-has-result :on message :check
 (if (eq (message-msg-type message) :response)
     (not (null (message-response-result message)))
     t))

(mcp-lisp/src/spec/serialization::definvariant sender-receiver-differ :on message :check
 (not (equal (message-sender-id message) (message-receiver-id message))))

(mcp-lisp/src/spec/serialization::definvariant payload-decision-consistent :on message :check
 (if (and (eq (message-msg-type message) :response) (not (null (message-response-result message))))
     (if (>= (message-payload message) (config :threshold))
         (eq (message-response-result message) :accept)
         (eq (message-response-result message) :reject))
     t))

(mcp-lisp/src/spec/serialization::defscenario request-response-cycle :entities
 ((requester 1 node) (responder 1 node) (request-msg 1 message) (response-msg 1 message)))

(mcp-lisp/src/spec/serialization::definvariant requester-role-correct :on request-response-cycle
 :check (eq (node-role requester) :requester))

(mcp-lisp/src/spec/serialization::definvariant responder-role-correct :on request-response-cycle
 :check (eq (node-role responder) :responder))

(mcp-lisp/src/spec/serialization::definvariant request-msg-type :on request-response-cycle :check
 (eq (message-msg-type request-msg) :request))

(mcp-lisp/src/spec/serialization::definvariant response-msg-type :on request-response-cycle :check
 (eq (message-msg-type response-msg) :response))

(mcp-lisp/src/spec/serialization::definvariant request-sender-is-requester :on
 request-response-cycle :check (equal (message-sender-id request-msg) (node-id requester)))

(mcp-lisp/src/spec/serialization::definvariant request-receiver-is-responder :on
 request-response-cycle :check (equal (message-receiver-id request-msg) (node-id responder)))

(mcp-lisp/src/spec/serialization::definvariant response-sender-is-responder :on
 request-response-cycle :check (equal (message-sender-id response-msg) (node-id responder)))

(mcp-lisp/src/spec/serialization::definvariant response-receiver-is-requester :on
 request-response-cycle :check (equal (message-receiver-id response-msg) (node-id requester)))

(mcp-lisp/src/spec/serialization::definvariant response-matches-payload :on request-response-cycle
 :check
 (let ((payload (message-payload request-msg)) (result (message-response-result response-msg)))
   (if (>= payload (config :threshold))
       (eq result :accept)
       (eq result :reject))))

(mcp-lisp/src/spec/serialization::definvariant requester-final-state-matches-response :on
 request-response-cycle :check
 (if (eq (message-delivery-status response-msg) :delivered)
     (let ((result (message-response-result response-msg)))
       (if (eq result :accept)
           (eq (node-status requester) :accepted)
           (eq (node-status requester) :rejected)))
     t))

(defgenerator message
    (overrides)
  (let* ((inst (default-generate-instance "message" overrides))
         (msg-type (getf inst :msg-type))
         (payload (getf inst :payload)))
    (cond ((eq msg-type :request) (setf (getf inst :response-result) nil))
          ((eq msg-type :response)
           (let ((threshold (config :threshold)))
             (unless (override-present-p overrides :response-result)
               (setf (getf inst :response-result)
                       (if (>= payload threshold)
                           :accept
                           :reject))))))
    inst))

(defscenario-generator request-response-cycle
    (overrides)
  (declare (ignore overrides))
  (let* ((requester (generate-instance "node" (list :role :requester)))
         (responder (generate-instance "node" (list :role :responder)))
         (req-id (node-id requester))
         (resp-id (node-id responder))
         (payload (generate-value 'integer :min 0 :max 100))
         (threshold (config :threshold))
         (result
          (if (>= payload threshold)
              :accept
              :reject))
         (delivered-p (> (random 2) 0))
         (requester-status
          (if delivered-p
              (if (eq result :accept)
                  :accepted
                  :rejected)
              :waiting))
         (request-msg
          (generate-instance "message"
                             (list :msg-type :request :sender-id req-id :receiver-id resp-id
                                   :payload payload :response-result nil :delivery-status
                                   :delivered)))
         (response-msg
          (generate-instance "message"
                             (list :msg-type :response :sender-id resp-id :receiver-id req-id
                                   :payload payload :response-result result :delivery-status
                                   (if delivered-p
                                       :delivered
                                       :pending)))))
    (setf (getf requester :status) requester-status)
    (setf (getf responder :status) :idle)
    (list :requester requester :responder responder :request-msg request-msg :response-msg
          response-msg)))

(defscenario-negative-generator request-response-cycle
    (overrides)
  (declare (ignore overrides))
  (let* ((requester (generate-instance "node" (list :role :requester :status :accepted)))
         (responder (generate-instance "node" (list :role :responder :status :idle)))
         (req-id (node-id requester))
         (resp-id (node-id responder))
         (payload (generate-value 'integer :min 0 :max 100))
         (threshold (config :threshold))
         (bad-result
          (if (>= payload threshold)
              :reject
              :accept))
         (request-msg
          (generate-instance "message"
                             (list :msg-type :request :sender-id req-id :receiver-id resp-id
                                   :payload payload :response-result nil :delivery-status
                                   :delivered)))
         (response-msg
          (generate-instance "message"
                             (list :msg-type :response :sender-id resp-id :receiver-id req-id
                                   :payload payload :response-result bad-result :delivery-status
                                   :delivered))))
    (list :requester requester :responder responder :request-msg request-msg :response-msg
          response-msg)))

;;;; examples/extraction-pipeline/pipeline.lisp
;;;;
;;;; Claude Architect — Exercise 3 (steps 1-3): a structured-data extraction
;;;; pipeline built spec-native on mcp-lisp.
;;;;
;;;;   * The extraction target is a `defentity` (publication). Its JSON Schema is
;;;;     DERIVED from the entity definition (entity->extraction-schema) — the spec
;;;;     is the single source of truth for both the tool schema and validation.
;;;;   * Claude is called with STRUCTURED OUTPUTS (output_config.format = that
;;;;     schema), so the response is guaranteed to match the shape; nullable
;;;;     fields let the model emit null for info absent from the source (step 1).
;;;;   * Extractions are validated with the spec engine's `check-invariants`
;;;;     (semantic rules structured outputs can't enforce). On a violation the
;;;;     pipeline re-prompts with the document + failed extraction + the specific
;;;;     violation, and retries (step 2). Few-shot examples in the system prompt
;;;;     cover varied document formats (step 3).
;;;;
;;;; The SDK is used only as a library (spec DSL + JSON + dexador).
;;;;
;;;;   examples/extraction-pipeline/run.sh

;;; --- Bootstrap: load mcp-lisp quietly (muffle the library's compile noise) ---
(let ((*standard-output* (make-broadcast-stream))
      (*trace-output* (make-broadcast-stream))
      (*error-output* *error-output*)
      (this-file (or *load-truename* *default-pathname-defaults*)))
  (let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file ql-setup) (load ql-setup)))
  (require :asdf)
  (let* ((here (make-pathname :directory (pathname-directory this-file)))
         (project-dir (truename (merge-pathnames "../../" here))))
    (eval `(pushnew ,project-dir ,(find-symbol "*CENTRAL-REGISTRY*" "ASDF") :test #'equal))
    (handler-bind ((warning #'muffle-warning)
                   #+sbcl (sb-ext:compiler-note #'muffle-warning))
      (funcall (find-symbol "LOAD-SYSTEM" "ASDF") :mcp-lisp :verbose nil :print nil))))

(defpackage #:extraction-pipeline
  (:use #:cl #:mcp-lisp/main))
(in-package #:extraction-pipeline)

;;; --- .env ---

(defun project-root ()
  (truename (merge-pathnames "../../"
                             (make-pathname :directory
                                            (pathname-directory
                                             (or *load-truename* *default-pathname-defaults*))))))

(defun load-dotenv ()
  (let ((path (merge-pathnames ".env" (project-root))) (key nil))
    (when (probe-file path)
      (with-open-file (in path)
        (loop for raw = (read-line in nil) while raw
              do (let ((line (string-trim '(#\Space #\Tab #\Return) raw)))
                   (when (and (plusp (length line)) (char/= (char line 0) #\#) (find #\= line))
                     (let ((pos (position #\= line)))
                       (when (string= "ANTHROPIC_API_KEY" (string-trim '(#\Space) (subseq line 0 pos)))
                         (setf key (string-trim '(#\Space #\") (subseq line (1+ pos)))))))))) )
    key))

(defparameter *model* "claude-opus-4-8")
(defparameter *max-tokens* 2048)
(defparameter *max-retries* 2)
(defvar *api-key* nil)

;;; --- The extraction spec (step 1: required/optional, enum+other, nullable) ---

(defentity publication ()
  (title        string :required t)
  (authors      (list-of string) :required t)
  (year         integer :nullable t :min 1900 :max 2026)
  (venue        string  :nullable t)
  (doi          string  :nullable t)
  (pub-type     (member :journal :conference :preprint :book :other) :required t)
  (other-detail string  :nullable t))

(definvariant other-requires-detail :on publication
  :check (or (not (eq (publication-pub-type publication) :other))
             (and (publication-other-detail publication)
                  (plusp (length (publication-other-detail publication))))))

(definvariant plausible-year :on publication
  :check (or (null (publication-year publication))
             (<= 1900 (publication-year publication) 2026)))

;; Human-readable feedback for the retry loop, keyed by invariant name.
(defparameter *invariant-help*
  '(("other-requires-detail" . "When pub_type is \"other\", other_detail must be a non-empty phrase naming the actual type (e.g. \"technical report\").")
    ("plausible-year" . "year must be between 1900 and 2026, or null if the source does not state it. Do not invent a year.")))

;;; --- Derive the JSON Schema from the entity (single source of truth) ---

(defun jname (sym) (string-downcase (substitute #\_ #\- (symbol-name sym))))
(defun field-kw (sym) (intern (symbol-name sym) :keyword))
(defun jnull () (find-symbol "NULL" "COM.INUOE.JZON"))
(defun nullish (v) (or (null v) (eq v (jnull))))

(defun type->schema (ty)
  (cond
    ((eq ty 'string) (make-ht "type" "string"))
    ((eq ty 'integer) (make-ht "type" "integer"))
    ((eq ty 'number) (make-ht "type" "number"))
    ((eq ty 'boolean) (make-ht "type" "boolean"))
    ((and (consp ty) (eq (car ty) 'list-of))
     (make-ht "type" "array" "items" (type->schema (cadr ty))))
    ((and (consp ty) (eq (car ty) 'member))
     (make-ht "type" "string"
              "enum" (map 'vector (lambda (k) (string-downcase (symbol-name k))) (cdr ty))))
    (t (make-ht "type" "string"))))

(defun field->prop (type nullable)
  (let ((s (type->schema type)))
    (when nullable
      (if (gethash "enum" s)
          (setf (gethash "enum" s)
                (concatenate 'vector (gethash "enum" s) (vector (jnull))))
          (setf (gethash "type" s) (vector (gethash "type" s) "null"))))
    s))

(defun entity->extraction-schema (entity)
  "Build an Anthropic structured-outputs JSON Schema from ENTITY's fields."
  (let ((props (make-hash-table :test #'equal)) (req '()))
    (dolist (f (entity-fields entity))
      (destructuring-bind (name type &rest opts) f
        (setf (gethash (jname name) props) (field->prop type (getf opts :nullable)))
        (push (jname name) req)))
    (make-ht "type" "object"
             "properties" props
             "required" (coerce (nreverse req) 'vector)
             "additionalProperties" nil)))

(defparameter *schema* (entity->extraction-schema 'publication))

;;; --- JSON (decoded) -> spec instance plist ---

(defun json-val->lisp (type v)
  (cond
    ((nullish v) nil)
    ((and (consp type) (eq (car type) 'member)) (intern (string-upcase v) :keyword))
    ((and (consp type) (eq (car type) 'list-of)) (coerce v 'list))
    (t v)))

(defun json->instance (entity hash)
  (let ((inst '()))
    (dolist (f (entity-fields entity) (nreverse inst))
      (destructuring-bind (name type &rest opts) f
        (declare (ignore opts))
        (push (field-kw name) inst)
        (push (json-val->lisp type (gethash (jname name) hash)) inst)))))

;;; --- Prompt (step 3: few-shot across document formats) ---

(defparameter *system-prompt*
  "You extract publication metadata from text into the provided JSON schema.

Rules:
- Use null for any nullable field whose value is NOT present in the text. Do not
  guess, infer, or fabricate. It is correct and expected to return null.
- pub_type is one of journal, conference, preprint, book, other. Use \"other\"
  only when none fit, and then set other_detail to a short phrase naming the
  actual type (e.g. \"technical report\", \"blog post\").
- year: the 4-digit publication year, or null if the text does not state it.

Examples (varied formats):

Bibliography entry:
  Vaswani, A., et al. \"Attention Is All You Need.\" Advances in Neural Information Processing Systems, 2017.
  -> {\"title\":\"Attention Is All You Need\",\"authors\":[\"Vaswani, A.\"],\"year\":2017,\"venue\":\"Advances in Neural Information Processing Systems\",\"doi\":null,\"pub_type\":\"conference\",\"other_detail\":null}

Inline narrative:
  As Smith and Jones showed in their 2019 Nature paper on coral resilience, ...
  -> {\"title\":\"coral resilience\",\"authors\":[\"Smith\",\"Jones\"],\"year\":2019,\"venue\":\"Nature\",\"doi\":null,\"pub_type\":\"journal\",\"other_detail\":null}

Informal mention with missing data:
  Someone shared a preprint called \"Scaling Laws\" — not sure who wrote it or when.
  -> {\"title\":\"Scaling Laws\",\"authors\":[],\"year\":null,\"venue\":null,\"doi\":null,\"pub_type\":\"preprint\",\"other_detail\":null}")

;;; --- Anthropic call with structured outputs ---

(defun anthropic-headers ()
  `(("x-api-key" . ,*api-key*)
    ("anthropic-version" . "2023-06-01")
    ("content-type" . "application/json")))

(defun http-post-json (url body)
  (handler-case
      (decode-json (dex:post url :headers (anthropic-headers)
                                 :content (encode-json body) :read-timeout 120))
    (dexador.error:http-request-failed (e)
      (error "Anthropic API ~a: ~a" (dexador.error:response-status e)
             (dexador.error:response-body e)))))

(defun http-get-text (url)
  (handler-case
      (let ((body (dex:get url :headers (anthropic-headers) :read-timeout 120)))
        ;; The batch results_url is served as binary; decode octets to a string.
        (if (stringp body) body
            (sb-ext:octets-to-string body :external-format :utf-8)))
    (dexador.error:http-request-failed (e)
      (error "Anthropic API ~a: ~a" (dexador.error:response-status e)
             (dexador.error:response-body e)))))

(defun message-params (messages &key (schema *schema*) (system *system-prompt*))
  "Build the Messages-API params body shared by single calls and batch requests."
  (make-ht "model" *model*
           "max_tokens" *max-tokens*
           "system" system
           "messages" (coerce messages 'vector)
           "output_config" (make-ht "format" (make-ht "type" "json_schema" "schema" schema))))

(defun response-text (resp)
  "Concatenate the text blocks of a Messages-API response."
  (with-output-to-string (s)
    (loop for b across (or (gethash "content" resp) #())
          when (string= "text" (gethash "type" b))
            do (write-string (gethash "text" b) s))))

(defun call-extract (messages &key (schema *schema*) (system *system-prompt*))
  "Call Claude with structured outputs. Returns the JSON extraction text."
  (response-text (http-post-json "https://api.anthropic.com/v1/messages"
                                 (message-params messages :schema schema :system system))))

(defun validate (instance)
  "Returns (:PASS) or (:FAIL \"name\" ...)."
  (check-invariants 'publication instance))

(defun violations-feedback (fail-result)
  "Render the failed-invariant names as actionable guidance for the model."
  (format nil "~{- ~a~%~}"
          (mapcar (lambda (name) (or (cdr (assoc name *invariant-help* :test #'string=)) name))
                  (rest fail-result))))

;;; --- Extraction with validation-retry loop (step 2) ---

(defun extract-with-retry (document &key (label ""))
  "Extract, validate, and re-prompt on invariant violations. Returns
 (values instance status attempts) where status is :ok | :unresolved."
  (let ((messages (list (make-ht "role" "user"
                                 "content" (format nil "Extract the publication metadata from this text:~%~%~a" document)))))
    (loop for attempt from 1 to (1+ *max-retries*)
          do (let* ((json-text (call-extract messages))
                    (decoded (decode-json json-text))
                    (instance (json->instance 'publication decoded))
                    (result (validate instance)))
               (format t "~&[~a] attempt ~a: ~a~%      ~a~%" label attempt json-text result)
               (cond
                 ((eq (first result) :pass)
                  (return (values instance :ok attempt)))
                 ((= attempt (1+ *max-retries*))
                  (return (values instance :unresolved attempt)))
                 (t
                  ;; re-prompt with the failed extraction + specific violations
                  (setf messages
                        (append messages
                                (list (make-ht "role" "assistant" "content" json-text)
                                      (make-ht "role" "user"
                                               "content" (format nil "That extraction failed validation:~%~a~%Re-extract from the same text, fixing only these issues. Use null where the text gives no value."
                                                                 (violations-feedback result)))))))))) ))

;;; --- Null audit (step 1: null, not fabrication) ---

(defun null-audit (instance)
  (let ((nulls '()) (present '()))
    (dolist (f (entity-fields 'publication))
      (destructuring-bind (name type &rest opts) f
        (declare (ignore type))
        (when (getf opts :nullable)
          (if (getf instance (field-kw name))
              (push (jname name) present)
              (push (jname name) nulls)))))
    (format t "      nullable -> null: ~{~a~^, ~}~@[ | present: ~{~a~^, ~}~]~%"
            (nreverse nulls) (nreverse present))))

;;; --- Sample documents ---

(defparameter *documents*
  (list
   (cons "full-bibliography"
         "Devlin, J., Chang, M.-W., Lee, K., & Toutanova, K. (2019). BERT: Pre-training of Deep Bidirectional Transformers for Language Understanding. In Proceedings of NAACL-HLT 2019. https://doi.org/10.18653/v1/N19-1423")
   (cons "sparse-narrative"
         "A colleague mentioned an interesting preprint titled \"Emergent Abilities of Large Language Models\" — I don't remember the authors offhand, and it never went through a venue as far as I know.")
   (cons "tricky-other"
         "Attached is the postmortem document \"Root Cause Analysis of the April Outage\", written by the SRE team and circulated internally on the company wiki in 2024.")))

;;; --- Step 4: Message Batches API ---

(defun http-get-json (url) (decode-json (http-get-text url)))

(defparameter *batch-sla-seconds* 3600
  "SLA target for the whole batch (Anthropic batches usually finish well within 1h).")

(defun extract-message (document)
  (list (make-ht "role" "user"
                 "content" (format nil "Extract the publication metadata from this text:~%~%~a" document))))

(defun submit-batch (docs)
  "DOCS is an alist (custom-id . document). Returns the batch id."
  (let* ((requests (map 'vector
                        (lambda (pair)
                          (make-ht "custom_id" (car pair)
                                   "params" (message-params (extract-message (cdr pair)))))
                        docs))
         (resp (http-post-json "https://api.anthropic.com/v1/messages/batches"
                               (make-ht "requests" requests))))
    (gethash "id" resp)))

(defun poll-batch (id &key (max-wait 540) (interval 15))
  "Poll until processing_status is \"ended\" or MAX-WAIT seconds elapse.
Returns the batch object."
  (let ((start (get-universal-time))
        (url (format nil "https://api.anthropic.com/v1/messages/batches/~a" id)))
    (loop
      (let* ((b (http-get-json url))
             (status (gethash "processing_status" b))
             (elapsed (- (get-universal-time) start)))
        (format t "      [batch] ~a (~as elapsed)~%" status elapsed)
        (force-output)
        (when (or (string= status "ended") (> elapsed max-wait))
          (return b))
        (sleep interval)))))

(defun batch-results (batch-obj)
  "custom_id -> result hash, parsed from the JSONL results_url."
  (let ((url (gethash "results_url" batch-obj))
        (out (make-hash-table :test #'equal)))
    (when url
      (with-input-from-string (s (http-get-text url))
        (loop for line = (read-line s nil) while line
              when (plusp (length (string-trim '(#\Space #\Tab #\Return) line)))
                do (let ((r (decode-json line)))
                     (setf (gethash (gethash "custom_id" r) out) r)))))
    out))

(defun run-batch-demo ()
  (format t "~&========== Step 4: Message Batches ==========~%")
  (let* ((docs (append (mapcar (lambda (d) (cons (car d) (cdr d))) *documents*)
                       (list (cons "extra-journal"
                                   "Hochreiter, S., & Schmidhuber, J. (1997). Long Short-Term Memory. Neural Computation, 9(8), 1735-1780."))))
         (start (get-universal-time))
         (id (submit-batch docs)))
    (format t "submitted ~a requests as batch ~a~%" (length docs) id)
    (let* ((final (poll-batch id))
           (status (gethash "processing_status" final)))
      (if (string/= status "ended")
          (format t "batch not finished within wait window (status ~a). Check later with batch id ~a~%" status id)
          (let ((results (batch-results final))
                (elapsed (- (get-universal-time) start))
                (succ 0) (failed '()))
            (dolist (pair docs)
              (let* ((cid (car pair))
                     (r (gethash cid results))
                     (res (and r (gethash "result" r)))
                     (rtype (and res (gethash "type" res))))
                (cond
                  ((and res (string= rtype "succeeded"))
                   (let* ((text (response-text (gethash "message" res)))
                          (inst (json->instance 'publication (decode-json text))))
                     (incf succ)
                     (format t "  [~a] ok  validate=~a~%" cid (validate inst))))
                  (t (push cid failed)
                     (format t "  [~a] FAILED (type=~a)~%" cid rtype)))))
            (format t "~%summary: ~a/~a succeeded; elapsed ~as vs SLA ~as -> ~a~%"
                    succ (length docs) elapsed *batch-sla-seconds*
                    (if (<= elapsed *batch-sla-seconds*) "WITHIN SLA" "OVER SLA"))
            (if failed
                (format t "resubmit strategy: re-batch ~a failed doc(s), chunking any oversized inputs: ~{~a~^, ~}~%"
                        (length failed) failed)
                (format t "no failures to resubmit (oversized docs would be chunked and re-batched).~%")))))))

;;; --- Step 5: field-level confidence + human-review routing ---

(defparameter *confidence-threshold* 0.7)

(defparameter *confidence-system-prompt*
  (concatenate 'string *system-prompt*
               (format nil "~%~%Additionally output a \"confidence\" object: a number 0.0-1.0 per field for how directly the source supports your value. Inferred values or nulls for missing info get LOW confidence; values stated verbatim get HIGH confidence. Shape: {\"extraction\": {...}, \"confidence\": {...}}.")))

(defun confidence-schema ()
  (let ((conf-props (make-hash-table :test #'equal)) (req '()))
    (dolist (f (entity-fields 'publication))
      (let ((jn (jname (first f))))
        ;; no minimum/maximum — structured outputs rejects numeric constraints
        (setf (gethash jn conf-props) (make-ht "type" "number"))
        (push jn req)))
    (make-ht "type" "object"
             "properties" (make-ht "extraction" *schema*
                                   "confidence" (make-ht "type" "object"
                                                         "properties" conf-props
                                                         "required" (coerce (nreverse req) 'vector)
                                                         "additionalProperties" nil))
             "required" (vector "extraction" "confidence")
             "additionalProperties" nil)))

(defun extract-with-confidence (document)
  "Returns (values instance confidence-hash)."
  (let* ((text (call-extract (extract-message document)
                             :schema (confidence-schema) :system *confidence-system-prompt*))
         (decoded (decode-json text)))
    (values (json->instance 'publication (gethash "extraction" decoded))
            (gethash "confidence" decoded))))

(defun route-for-review (confidence)
  "Field json-names (with score) whose confidence is below the threshold."
  (let ((low '()))
    (when (hash-table-p confidence)
      (maphash (lambda (field score)
                 (when (and (numberp score) (< score *confidence-threshold*))
                   (push (cons field score) low)))
               confidence))
    (sort low #'< :key #'cdr)))

(defparameter *gold-set*
  (list
   (list "lstm"
         "Hochreiter, S., & Schmidhuber, J. (1997). Long Short-Term Memory. Neural Computation, 9(8), 1735-1780."
         (list :year 1997 :venue "Neural Computation" :pub-type :journal))
   (list "blog"
         "I really enjoyed Karpathy's 2015 blog post \"The Unreasonable Effectiveness of Recurrent Neural Networks\"."
         (list :year 2015 :pub-type :other))))

(defun field-correct-p (gold-val ev)
  (if (and (stringp gold-val) (stringp ev))
      (string-equal (string-trim " " gold-val) (string-trim " " ev))
      (equal gold-val ev)))

(defun run-review-demo ()
  (format t "~&========== Step 5: confidence + human-review routing ==========~%")
  (let ((correct (make-hash-table :test #'eq))
        (total (make-hash-table :test #'eq)))
    (dolist (g *gold-set*)
      (destructuring-bind (label doc gold) g
        (format t "~&----- ~a -----~%~a~%" label doc)
        (multiple-value-bind (inst conf) (extract-with-confidence doc)
          (format t "  extraction: ~s~%  validate: ~s~%" inst (validate inst))
          (let ((low (route-for-review conf)))
            (if low
                (format t "  -> ROUTE TO HUMAN REVIEW (low-confidence fields): ~{~a~^, ~}~%"
                        (mapcar (lambda (c) (format nil "~a=~,2f" (car c) (cdr c))) low))
                (format t "  -> auto-accept (all fields >= ~a)~%" *confidence-threshold*)))
          (loop for (field gv) on gold by #'cddr
                do (incf (gethash field total 0))
                   (when (field-correct-p gv (getf inst field))
                     (incf (gethash field correct 0)))))))
    (format t "~&----- accuracy by field (vs gold) -----~%")
    (maphash (lambda (field tot) (format t "  ~a: ~a/~a~%" (jname field) (gethash field correct 0) tot))
             total)))

;;; --- Run ---

(defun run-demo ()
  (format t "~&========== Extraction Pipeline (Exercise 3, steps 1-3) ==========~%")
  (format t "Schema (derived from defentity publication):~%~a~%~%"
          (encode-json *schema*))
  (dolist (doc *documents*)
    (format t "~&----- ~a -----~%~a~%" (car doc) (cdr doc))
    (multiple-value-bind (instance status attempts) (extract-with-retry (cdr doc) :label (car doc))
      (format t "      => status: ~a (after ~a attempt~:p)~%" status attempts)
      (null-audit instance)))
  ;; Step 2, explicit: drive the repair path with a seeded BAD extraction so the
  ;; retry/repair mechanism is demonstrated even if the live model never trips.
  (format t "~&----- forced-repair demo (seeded invalid extraction) -----~%")
  (let* ((doc (cdr (assoc "tricky-other" *documents* :test #'string=)))
         (bad-json "{\"title\":\"Root Cause Analysis of the April Outage\",\"authors\":[\"SRE team\"],\"year\":2024,\"venue\":null,\"doi\":null,\"pub_type\":\"other\",\"other_detail\":null}")
         (bad-inst (json->instance 'publication (decode-json bad-json)))
         (result (validate bad-inst)))
    (format t "seeded extraction: ~a~%      validates: ~a~%" bad-json result)
    (let ((messages (list (make-ht "role" "user" "content" (format nil "Extract the publication metadata from this text:~%~%~a" doc))
                          (make-ht "role" "assistant" "content" bad-json)
                          (make-ht "role" "user" "content" (format nil "That extraction failed validation:~%~a~%Re-extract, fixing only these issues."
                                                                   (violations-feedback result))))))
      (let* ((fixed-json (call-extract messages))
             (fixed (json->instance 'publication (decode-json fixed-json))))
        (format t "      repaired: ~a~%      validates: ~a~%" fixed-json (validate fixed))))))

(defun main ()
  (setf *api-key* (or (uiop:getenv "ANTHROPIC_API_KEY") (load-dotenv)))
  (unless *api-key*
    (format *error-output* "No ANTHROPIC_API_KEY in env or project .env~%")
    (uiop:quit 1))
  (let ((mode (or (first (uiop:command-line-arguments)) "extract")))
    (cond
      ((string= mode "extract") (run-demo))
      ((string= mode "batch")   (run-batch-demo))
      ((string= mode "review")  (run-review-demo))
      ((string= mode "all")     (run-demo) (run-batch-demo) (run-review-demo))
      (t (format t "unknown mode ~a (use: extract | batch | review | all)~%" mode)))))

(unless (find-package '#:slynk)
  (main)
  (sb-ext:exit))

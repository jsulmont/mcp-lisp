;;;; examples/sampling-demo/client.lisp
;;;;
;;;; The host side of the sampling demo. It connects to the sampling-demo server
;;;; over Streamable HTTP and:
;;;;
;;;;   * prints notifications/progress and notifications/message LIVE as the
;;;;     server's tool runs (progress + logging);
;;;;   * answers the server's sampling/createMessage request by calling the
;;;;     Anthropic API (ANTHROPIC_API_KEY) — the server borrows *our* model.
;;;;
;;;; Start the server first, then:
;;;;   sbcl --script examples/sampling-demo/client.lisp "your question"

;;; --- Bootstrap ---
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
    (funcall (find-symbol "LOAD-SYSTEM" "ASDF") :mcp-lisp :verbose nil :print nil)))

(defpackage #:sampling-demo-client
  (:use #:cl #:mcp-lisp/main))
(in-package #:sampling-demo-client)

;;; --- .env loading ---

(defun project-root ()
  (truename (merge-pathnames "../../"
                             (make-pathname :directory
                                            (pathname-directory
                                             (or *load-truename* *default-pathname-defaults*))))))

(defun load-dotenv (path)
  (let ((table (make-hash-table :test #'equal)))
    (when (probe-file path)
      (with-open-file (s path :if-does-not-exist nil)
        (when s
          (loop for line = (read-line s nil nil) while line
                do (let ((line (string-trim '(#\Space #\Tab #\Return) line)))
                     (unless (or (zerop (length line)) (char= (char line 0) #\#))
                       (let ((eq (position #\= line)))
                         (when eq
                           (setf (gethash (string-trim " " (subseq line 0 eq)) table)
                                 (string-trim " " (subseq line (1+ eq))))))))))))
    table))

(defparameter *env* (load-dotenv (merge-pathnames ".env" (project-root))))
(defun env (key) (or (uiop:getenv key) (gethash key *env*)))

;;; --- Sampling handler: MCP sampling/createMessage -> Anthropic ---

;; Current Anthropic model ID. Sonnet 4.6 and Haiku 4.5 accept the `temperature`
;; this handler forwards; Opus 4.8 would 400 on it (drop temperature to use Opus).
(defparameter *model* "claude-sonnet-4-6")

(defun message-text (msg)
  "Pull plain text out of an MCP sampling message's content (block or array)."
  (let ((content (gethash "content" msg)))
    (cond
      ((stringp content) content)
      ((and (hash-table-p content) (gethash "text" content)) (gethash "text" content))
      ((vectorp content)
       (with-output-to-string (s)
         (loop for block across content
               when (and (hash-table-p block) (gethash "text" block))
                 do (write-string (gethash "text" block) s))))
      (t ""))))

(defun create-message (params)
  "Handle sampling/createMessage by calling Anthropic. Returns an MCP result."
  (let ((key (env "ANTHROPIC_API_KEY")))
    (unless key (error "ANTHROPIC_API_KEY not set"))
    (let* ((messages (map 'vector
                          (lambda (m) (make-ht "role" (gethash "role" m)
                                               "content" (message-text m)))
                          (gethash "messages" params)))
           (system (gethash "systemPrompt" params))
           (max-tokens (or (gethash "maxTokens" params) 1024))
           (temperature (gethash "temperature" params))
           (body (make-ht "model" *model*
                          "max_tokens" max-tokens
                          "messages" messages)))
      (when system (setf (gethash "system" body) system))
      (when temperature (setf (gethash "temperature" body) temperature))
      (let* ((resp (decode-json
                    (dex:post "https://api.anthropic.com/v1/messages"
                              :headers `(("x-api-key" . ,key)
                                         ("anthropic-version" . "2023-06-01")
                                         ("content-type" . "application/json"))
                              :content (encode-json body)
                              :read-timeout 60)))
             (blocks (gethash "content" resp))
             (text (with-output-to-string (s)
                     (loop for b across (or blocks #())
                           when (string= "text" (gethash "type" b))
                             do (write-string (gethash "text" b) s))))
             (stop (gethash "stop_reason" resp)))
        (make-ht "role" "assistant"
                 "content" (make-ht "type" "text" "text" text)
                 "model" (or (gethash "model" resp) *model*)
                 "stopReason" (if (string= (or stop "") "end_turn") "endTurn" (or stop "endTurn")))))))

;;; --- Notification printing (progress + logging) ---

(defun on-notification (method params)
  (cond
    ((string= method "notifications/progress")
     (let ((p (gethash "progress" params))
           (total (gethash "total" params))
           (msg (gethash "message" params)))
       (format t "  progress ~@[~a~]~@[/~a~]  ~@[~a~]~%" p total msg)
       (force-output)))
    ((string= method "notifications/message")
     (format t "  log [~a] ~a~%" (gethash "level" params) (gethash "data" params))
     (force-output))
    (t (format t "  notif ~a~%" method) (force-output))))

;;; --- Run ---

(defparameter *topic*
  (let ((args (cdr sb-ext:*posix-argv*)))
    (or (find-if (lambda (a) (and (plusp (length a))
                                  (not (char= (char a 0) #\-))
                                  (not (search ".lisp" a))))
                 args)
        "What is the Model Context Protocol and who created it?")))

;; Only run when the SDK key the sampling handler needs is available.
(unless (env "ANTHROPIC_API_KEY")
  (format t "~&[sampling-demo] ANTHROPIC_API_KEY is not set.~%~
This client answers the server's sampling/createMessage by calling Claude. Add~%~
  ANTHROPIC_API_KEY=...~%~
to the project-root .env (or export it), then run again. Skipping.~%")
  (sb-ext:exit :code 0))

(let ((client (make-http-client "http://localhost:8080/mcp")))
  (client-connect client)
  (client-initialize client)
  (setf (client-notification-handler client) #'on-notification)
  (setf (client-request-handler client)
        (lambda (method params)
          (if (string= method "sampling/createMessage")
              (create-message params)
              (error "Unsupported server request: ~a" method))))
  ;; Ask the server to emit debug-level logs too.
  (client-call client "logging/setLevel" (make-ht "level" "debug"))

  (format t "~&Question: ~a~%~%" *topic*)
  ;; Pass a progressToken in _meta so the server's tool-report-progress calls are
  ;; actually delivered as notifications/progress (otherwise they no-op).
  (let* ((params (make-ht "name" "research"
                          "arguments" (make-ht "topic" *topic*)
                          "_meta" (make-ht "progressToken" "research-1")))
         (result (client-call client "tools/call" params :timeout 120))
         (content (gethash "content" result)))
    (format t "~%~a~%" (gethash "text" (aref content 0))))

  (client-disconnect client))

(sb-ext:exit)

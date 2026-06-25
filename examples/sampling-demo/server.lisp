;;;; examples/sampling-demo/server.lisp
;;;;
;;;; An MCP server demonstrating three server->client features together:
;;;;
;;;;   * logging   — `tool-log` emits notifications/message
;;;;   * progress  — `tool-report-progress` emits notifications/progress
;;;;   * sampling  — `tool-sample` asks the CLIENT's LLM to complete a prompt
;;;;
;;;; The `research` tool searches the web with Tavily (server-side, using
;;;; TAVILY_API_KEY) and then delegates the *synthesis* of an answer to the
;;;; calling client's model via MCP sampling. The server never holds an LLM key
;;;; for the synthesis step — that is the whole point of sampling: the host owns
;;;; the model, the server borrows it.
;;;;
;;;; Sampling and progress only flow over a transport that can carry
;;;; server->client messages, so this server runs on Streamable HTTP (Woo).
;;;;
;;;;   sbcl --load examples/sampling-demo/server.lisp
;;;;   # then, in another terminal:
;;;;   sbcl --load examples/sampling-demo/client.lisp "your question"

;;; --- Bootstrap: load Quicklisp + ASDF, keep stdout clean ---
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

(defpackage #:sampling-demo-server
  (:use #:cl #:mcp-lisp/main))
(in-package #:sampling-demo-server)

;;; --- .env loading: keys live in the project-root .env, never in code ---

(defun project-root ()
  (truename (merge-pathnames "../../"
                             (make-pathname :directory
                                            (pathname-directory
                                             (or *load-truename* *default-pathname-defaults*))))))

(defun load-dotenv (path)
  "Parse a KEY=VALUE .env file into a hash-table (ignores blanks and # comments)."
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

(defun env (key)
  (or (uiop:getenv key) (gethash key *env*)))

;;; --- Tavily web search (server-side) ---

(defun tavily-search (query max-results)
  "Search the web via Tavily. Returns a list of (title url content) lists."
  (let ((key (env "TAVILY_API_KEY")))
    (unless key (error "TAVILY_API_KEY not set"))
    (let* ((body (encode-json (make-ht "api_key" key
                                       "query" query
                                       "max_results" max-results
                                       "search_depth" "basic"
                                       "include_answer" nil)))
           (resp (decode-json
                  (dex:post "https://api.tavily.com/search"
                            :headers '(("Content-Type" . "application/json"))
                            :content body
                            :read-timeout 30)))
           (results (gethash "results" resp)))
      (map 'list (lambda (r)
                   (list (gethash "title" r) (gethash "url" r) (gethash "content" r)))
           (or results #())))))

;;; --- The research tool ---

(defun format-sources (results)
  "Render search results as a numbered context block for the LLM."
  (with-output-to-string (s)
    (loop for (title url content) in results
          for i from 1
          do (format s "[~a] ~a~%~a~%~a~%~%" i title url content))))

(define-tool research ((topic string "The question or topic to research" :required t)
                       (max-results integer "How many web results to use" :default 5))
  "Search the web for TOPIC, then ask the calling client's LLM to synthesize a
cited answer from the results. Streams progress and log notifications throughout."
  (:annotations :read-only t :open-world t)
  (cond
    ((not (tool-streaming-available-p))
     (tool-log "error" "research requires a streaming transport (sampling unavailable)")
     "This tool needs a client that supports MCP sampling over a streaming transport.")
    (t
     (tool-log "info" (format nil "Researching: ~a" topic))
     (tool-report-progress 0 :total 4 :message "Searching the web")
     (let ((results (handler-case (tavily-search topic max-results)
                      (error (e)
                        (tool-log "error" (format nil "Web search failed: ~a" e))
                        nil))))
       (tool-report-progress 1 :total 4
                             :message (format nil "Found ~a result(s)" (length results)))
       (tool-log "info" (format nil "~a web result(s) retrieved" (length results)))
       (cond
         ((null results)
          (tool-report-progress 4 :total 4 :message "No results")
          "No web results were found (or the search failed). Try a different query.")
         (t
          (tool-report-progress 2 :total 4 :message "Asking your model to synthesize (sampling)")
          (tool-log "debug" "Issuing sampling/createMessage to the client")
          (let* ((sources (format-sources results))
                 (prompt (format nil
                                 "Using only the numbered web search results below, ~
write a concise, accurate answer to the question. Cite sources inline as [n]. ~
If the results don't answer it, say so.~%~%Question: ~a~%~%Results:~%~a"
                                 topic sources))
                 (reply (tool-sample
                         (list (make-sampling-message "user" prompt))
                         :system-prompt "You are a careful research assistant. Cite sources as [n]."
                         :max-tokens 700
                         :temperature 0.2))
                 (content (and (hash-table-p reply) (gethash "content" reply)))
                 (text (and (hash-table-p content) (gethash "text" content)))
                 (model (and (hash-table-p reply) (gethash "model" reply))))
            (tool-report-progress 3 :total 4 :message "Formatting answer")
            (tool-log "info" (format nil "Synthesis complete (model: ~a)" (or model "?")))
            (tool-report-progress 4 :total 4 :message "Done")
            (format nil "~a~%~%--- Sources ---~%~{~a~%~}"
                    (or text "(no answer returned)")
                    (loop for (title url) in results
                          for i from 1
                          collect (format nil "[~a] ~a — ~a" i title url))))))))))

;;; --- Start the server ---

;; Only run when the key the research tool needs is available.
(unless (env "TAVILY_API_KEY")
  (format t "~&[sampling-demo] TAVILY_API_KEY is not set.~%~
This demo's `research` tool searches the web with Tavily. Add~%~
  TAVILY_API_KEY=...~%~
to the project-root .env (or export it), then start the server again.~%~
Not starting.~%")
  (sb-ext:exit :code 0))

(defparameter *port* 8080)
(format t "~&Sampling demo server on http://localhost:~a/mcp~%" *port*)
(format t "Run the client:  sbcl --script examples/sampling-demo/client.lisp \"your question\"~%~%")
(run-server :name "sampling-demo" :version "1.0.0" :transport :sse :port *port*)
(loop (sleep 3600))

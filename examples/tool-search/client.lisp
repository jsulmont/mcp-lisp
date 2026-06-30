;;;; examples/tool-search/client.lisp
;;;;
;;;; Connects over HTTP to the cloud-ops MCP server (server.lisp), bridges its 12
;;;; tools into an agent registry, enables the Anthropic server-side tool search
;;;; tool (deferring every bridged tool), and runs the agent against the real
;;;; Anthropic API.
;;;;
;;;; Because all 12 tools are deferred, the model starts with only the tool
;;;; search tool in context and must search the catalog to discover the tools it
;;;; needs — demonstrating defer_loading + tool_search_tool end to end.
;;;;
;;;; Start the server first (separate terminal), then run this:
;;;;   sbcl --load  examples/tool-search/server.lisp     # terminal 1 (watch it)
;;;;   sbcl --script examples/tool-search/client.lisp ["your prompt"]   # terminal 2
;;;;
;;;; Requires an Anthropic key in $ANTHROPIC_API_KEY or ~/.anthropic-key.

;; Wrapped in eval-when so the system (and thus the MCP-LISP/MAIN package) loads
;; at compile time too — otherwise Sly's C-c C-k (compile-file) hits the
;; defpackage below before mcp-lisp is loaded. *compile-file-truename* covers
;; the compile-file case where *load-truename* is nil.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((*standard-output* (make-broadcast-stream))
        (*trace-output* (make-broadcast-stream))
        (*error-output* *error-output*)
        (this-file (or *load-truename* *compile-file-truename*
                       *default-pathname-defaults*)))
    (let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
      (when (probe-file ql-setup)
        (load ql-setup)))
    (require :asdf)
    (let* ((this-dir (make-pathname :directory (pathname-directory this-file)))
           (project-dir (truename (merge-pathnames "../../" this-dir))))
      (eval `(pushnew ,project-dir ,(find-symbol "*CENTRAL-REGISTRY*" "ASDF") :test #'equal))
      (handler-bind ((warning #'muffle-warning)
                     #+sbcl (sb-ext:compiler-note #'muffle-warning))
        (funcall (find-symbol "LOAD-SYSTEM" "ASDF") :mcp-lisp :verbose nil :print nil)))))

(defpackage #:tool-search-client
  (:use #:cl #:mcp-lisp/main))

(in-package #:tool-search-client)

(defparameter *server-url* "http://localhost:8930/mcp"
  "Streamable-HTTP MCP endpoint of server.lisp (must be running).")

(defparameter *agent-model* "claude-sonnet-4-6"
  "A tool-search-capable model. Bump to claude-opus-4-8 for harder tasks.")

(defparameter *default-prompt*
  "Our production 'web' service has felt slow today and I'm worried about this
month's bill. Check the web service's health, pull recent CPU metrics for its
instances, scan its logs for errors, and give me the month-to-date billing
summary. Then summarize what's going on and whether cost is a concern.")

(defun bridge-tools (client)
  "List the server's tools and register each into a fresh registry with a
handler that proxies tools/call back to the server."
  (let ((registry (make-hash-table :test #'equal)))
    (dolist (tool (list-tools client) registry)
      (let ((name (gethash "name" tool)))
        (register-tool name
                       (gethash "description" tool)
                       (gethash "inputSchema" tool)
                       (let ((tool-name name))
                         (lambda (server session args)
                           (declare (ignore server session))
                           (gethash "content"
                                    (client-call client "tools/call"
                                                 (make-ht "name" tool-name
                                                          "arguments" (or args (make-ht)))))))
                       :registry registry)))))

(defun main (&optional (prompt (or (second sb-ext:*posix-argv*) *default-prompt*)))
  "Run the tool-search agent against the cloud-ops server. Returns T on success,
NIL on a handled precondition failure. Safe to call from the REPL (no exit)."
  ;; Keep log4cl off the console; the agent's own progress uses plain output.
  (log4cl:clear-logging-configuration)
  (log:config :daily "/tmp/tool-search-client.log" :backup nil)
  (unless mcp-lisp:*api-key*
    (format *error-output*
            "No Anthropic key found. Set ANTHROPIC_API_KEY or ~~/.anthropic-key.~%")
    (return-from main nil))
  (let ((client (make-http-client *server-url*)))
    (unwind-protect
         (progn
           (handler-case
               (progn (client-connect client)
                      (client-initialize client))
             (error (e)
               (format *error-output*
                       "~%Could not reach the cloud-ops server at ~a (~a).~%~
                        Start it first in another terminal:~%  sbcl --load server.lisp~%"
                       *server-url* e)
               (return-from main nil)))
           (let ((registry (bridge-tools client)))
             (format t "~%Bridged ~d tools from the cloud-ops MCP server.~%"
                     (hash-table-count registry))
             ;; *tool-search-keep-loaded* / *tool-search-defer-only* are left as
             ;; you set them (both default nil = defer everything). Tweak from the
             ;; REPL before calling (main), e.g.
             ;;   (setf mcp-lisp:*tool-search-keep-loaded* '("instance_list"))
             (setf mcp-lisp:*provider* :anthropic
                   mcp-lisp:*model* *agent-model*
                   mcp-lisp:*tool-search* :regex
                   mcp-lisp:*verbose* t)
             (format t "Tool search on; keep-loaded=~a defer-only=~a~%"
                     mcp-lisp:*tool-search-keep-loaded* mcp-lisp:*tool-search-defer-only*)
             (with-open-file (ts "/tmp/tool-search-agent.log"
                                 :direction :output :if-exists :supersede
                                 :if-does-not-exist :create)
               (let* ((mcp-lisp:*transcript* ts)
                      (answer (run-agent prompt
                                         :system "You are a cloud-operations assistant. A large catalog of tools is available but deferred — use the tool search tool to find tools before calling them. Tools are grouped by prefix: instance_, bucket_, log_, alert_, billing_, service_."
                                         :registry registry
                                         :max-iterations 15)))
                 (format t "~%~%========== FINAL ANSWER ==========~%~a~%" answer)
                 (format t "~%========== TOKEN USAGE ==========~%~
                            ~:d input, ~:d output, ~:d API requests~%"
                         (getf mcp-lisp:*session-tokens* :input)
                         (getf mcp-lisp:*session-tokens* :output)
                         (getf mcp-lisp:*session-tokens* :requests))
                 (format t "~%Full conversation transcript: /tmp/tool-search-agent.log~%")))
             t))
      (ignore-errors (client-shutdown client)))))

;; Auto-run only as a script. Under SLY/Slynk, loading the file just defines
;; everything — call (main) or (main "your prompt") by hand; no exit, no kill.
(unless (find-package '#:slynk)
  (sb-ext:exit :code (if (handler-case (main)
                           (error (e)
                             (format *error-output* "~%Error: ~a~%" e)
                             nil))
                         0 1)))

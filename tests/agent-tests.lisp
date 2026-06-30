;;;; tests/agent-tests.lisp
;;;;
;;;; Tests for the agent loop — tool conversion and server-side tool search.

(in-package #:mcp-lisp/tests)

(def-suite agent-tests :in mcp-lisp-tests)
(in-suite agent-tests)

(defun agent-test-registry ()
  (mcp-lisp/src/agent/agent:filter-registry '("eval_lisp" "shell")))

(defun find-tool-ht (tools name)
  (find name tools :key (lambda (ht) (gethash "name" ht)) :test #'equal))

(test anthropic-tools-no-search
  "Without tool search, tools carry no defer_loading and no search entry."
  (let ((mcp-lisp/src/agent/agent:*tool-search* nil)
        (tools (mcp-lisp/src/agent/agent::tools-for-anthropic (agent-test-registry))))
    (is (= 2 (length tools)))
    (loop for ht across tools
          do (is (null (nth-value 1 (gethash "defer_loading" ht))))
             (is (null (gethash "type" ht))))))

(test anthropic-tools-search-defers-all
  "With :regex search and no kept tools, every registry tool is deferred and the
search tool is appended last and non-deferred."
  (let* ((mcp-lisp/src/agent/agent:*tool-search* :regex)
         (mcp-lisp/src/agent/agent:*tool-search-keep-loaded* nil)
         (tools (mcp-lisp/src/agent/agent::tools-for-anthropic (agent-test-registry))))
    (is (= 3 (length tools)))
    (let ((search (aref tools (1- (length tools)))))
      (is (equal "tool_search_tool_regex_20251119" (gethash "type" search)))
      (is (equal "tool_search_tool_regex" (gethash "name" search)))
      (is (null (nth-value 1 (gethash "defer_loading" search)))))
    (dolist (name '("eval_lisp" "shell"))
      (is (eq t (gethash "defer_loading" (find-tool-ht tools name)))))))

(test anthropic-tools-search-keep-loaded
  "Tools named in *tool-search-keep-loaded* stay non-deferred."
  (let* ((mcp-lisp/src/agent/agent:*tool-search* :regex)
         (mcp-lisp/src/agent/agent:*tool-search-keep-loaded* '("eval_lisp"))
         (tools (mcp-lisp/src/agent/agent::tools-for-anthropic (agent-test-registry))))
    (is (null (nth-value 1 (gethash "defer_loading" (find-tool-ht tools "eval_lisp")))))
    (is (eq t (gethash "defer_loading" (find-tool-ht tools "shell"))))))

(test anthropic-tools-defer-only
  "*tool-search-defer-only* defers exactly the named tools; the rest load up front."
  (let* ((mcp-lisp/src/agent/agent:*tool-search* :regex)
         (mcp-lisp/src/agent/agent:*tool-search-keep-loaded* nil)
         (mcp-lisp/src/agent/agent:*tool-search-defer-only* '("shell"))
         (tools (mcp-lisp/src/agent/agent::tools-for-anthropic (agent-test-registry))))
    (is (eq t (gethash "defer_loading" (find-tool-ht tools "shell"))))
    (is (null (nth-value 1 (gethash "defer_loading" (find-tool-ht tools "eval_lisp")))))))

(test anthropic-tools-defer-only-precedence
  "*tool-search-defer-only* takes precedence over *tool-search-keep-loaded*."
  (let* ((mcp-lisp/src/agent/agent:*tool-search* :regex)
         (mcp-lisp/src/agent/agent:*tool-search-keep-loaded* '("shell"))
         (mcp-lisp/src/agent/agent:*tool-search-defer-only* '("eval_lisp"))
         (tools (mcp-lisp/src/agent/agent::tools-for-anthropic (agent-test-registry))))
    (is (eq t (gethash "defer_loading" (find-tool-ht tools "eval_lisp"))))
    (is (null (nth-value 1 (gethash "defer_loading" (find-tool-ht tools "shell")))))))

(test anthropic-tools-both-lists-warns
  "Setting both defer-only and keep-loaded signals a warning (keep-loaded ignored)."
  (let ((mcp-lisp/src/agent/agent:*tool-search* :regex)
        (mcp-lisp/src/agent/agent:*tool-search-defer-only* '("shell"))
        (mcp-lisp/src/agent/agent:*tool-search-keep-loaded* '("eval_lisp")))
    (signals warning
      (mcp-lisp/src/agent/agent::tools-for-anthropic (agent-test-registry)))))

(test anthropic-pause-turn-resumes
  "stop_reason pause_turn continues (not done) by re-appending the assistant turn."
  (let* ((content (vector (mcp-lisp:make-ht "type" "text" "text" "searching")
                          (mcp-lisp:make-ht "type" "server_tool_use" "id" "s1"
                                            "name" "tool_search_tool_regex"
                                            "input" (mcp-lisp:make-ht "pattern" "x"))))
         (response (mcp-lisp:make-ht "content" content "stop_reason" "pause_turn"))
         (messages (list (mcp-lisp:make-ht "role" "user" "content" "hi"))))
    (multiple-value-bind (done result new-messages)
        (mcp-lisp/src/agent/agent::process-anthropic-response
         response messages (make-hash-table :test #'equal))
      (is (null done))
      (is (null result))
      (is (= 2 (length new-messages)))
      (let ((appended (car (last new-messages))))
        (is (string= "assistant" (gethash "role" appended)))
        (is (eq content (gethash "content" appended)))))))

(test anthropic-max-tokens-warns-and-done
  "stop_reason max_tokens returns done with partial text and signals a warning."
  (let* ((content (vector (mcp-lisp:make-ht "type" "text" "text" "partial")))
         (response (mcp-lisp:make-ht "content" content "stop_reason" "max_tokens"))
         (messages (list (mcp-lisp:make-ht "role" "user" "content" "hi"))))
    (signals warning
      (mcp-lisp/src/agent/agent::process-anthropic-response
       response messages (make-hash-table :test #'equal)))
    (multiple-value-bind (done result)
        (handler-bind ((warning #'muffle-warning))
          (mcp-lisp/src/agent/agent::process-anthropic-response
           response messages (make-hash-table :test #'equal)))
      (is (eq t done))
      (is (string= "partial" result)))))

(test anthropic-end-turn-done-no-warning
  "stop_reason end_turn returns done with the text and no warning."
  (let* ((content (vector (mcp-lisp:make-ht "type" "text" "text" "all done")))
         (response (mcp-lisp:make-ht "content" content "stop_reason" "end_turn"))
         (messages (list (mcp-lisp:make-ht "role" "user" "content" "hi"))))
    (handler-bind ((warning (lambda (w) (declare (ignore w)) (fail "unexpected warning"))))
      (multiple-value-bind (done result)
          (mcp-lisp/src/agent/agent::process-anthropic-response
           response messages (make-hash-table :test #'equal))
        (is (eq t done))
        (is (string= "all done" result))))))

(test tool-search-entry-variants
  "Each *tool-search* value selects the matching server-tool definition."
  (let ((mcp-lisp/src/agent/agent:*tool-search* :bm25))
    (let ((entry (mcp-lisp/src/agent/agent::tool-search-entry)))
      (is (equal "tool_search_tool_bm25_20251119" (gethash "type" entry)))
      (is (equal "tool_search_tool_bm25" (gethash "name" entry)))))
  (let ((mcp-lisp/src/agent/agent:*tool-search* :regex))
    (is (equal "tool_search_tool_regex_20251119"
               (gethash "type" (mcp-lisp/src/agent/agent::tool-search-entry))))))

(test defer-loading-encodes-as-json-true
  "A deferred tool serializes defer_loading as JSON true."
  (let* ((mcp-lisp/src/agent/agent:*tool-search* :regex)
         (mcp-lisp/src/agent/agent:*tool-search-keep-loaded* nil)
         (tools (mcp-lisp/src/agent/agent::tools-for-anthropic (agent-test-registry)))
         (json (mcp-lisp:encode-json (find-tool-ht tools "shell"))))
    (is (search "\"defer_loading\":true" json))))

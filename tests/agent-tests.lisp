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

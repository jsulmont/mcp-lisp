;;;; mcp-lisp.asd

(asdf:defsystem "mcp-lisp"
  :class :package-inferred-system
  :description "Common Lisp SDK for Model Context Protocol and A2A"
  :author "Jan VL"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria"
               "serapeum"
               "bordeaux-threads"
               "log4cl"
               "woo"
               "dexador"
               "com.inuoe.jzon"
               "mcp-lisp/main")
  :in-order-to ((test-op (test-op "mcp-lisp/tests"))))

(asdf:defsystem "mcp-lisp/tests"
  :description "Tests for mcp-lisp"
  :depends-on ("mcp-lisp" "mcp-lisp/src/transport/worker-pool" "fiveam")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "json-tests")
               (:file "content-tests")
               (:file "conditions-tests")
               (:file "registry-tests")
               (:file "uri-template-tests")
               (:file "schema-tests")
               (:file "dispatcher-tests")
               (:file "a2a-tests")
               (:file "sse-tests")
               (:file "define-tool-tests")
               (:file "client-transport-tests")
               (:file "agent-tools-tests")
               (:file "worker-pool-tests")
               (:file "spec-tests")
               (:file "pbt-tests")
               (:file "transition-tests")
               (:file "codegen-tests")
               (:file "analysis-tests")
               (:file "dsl-features-tests")
               (:file "gaps-medium-tests")
               (:file "gaps-hard-tests")
               (:file "issues-tests"))
  :perform (test-op (o c)
                    (symbol-call :fiveam :run!
                                 (find-symbol "MCP-LISP-TESTS"
                                              :mcp-lisp/tests))))

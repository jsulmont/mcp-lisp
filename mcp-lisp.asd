;;;; mcp-lisp.asd

(asdf:defsystem "mcp-lisp"
  :class :package-inferred-system
  :description "Common Lisp SDK for Model Context Protocol and A2A"
  :author "Jan VL"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria"
               "bordeaux-threads"
               "log4cl"
               "hunchentoot"
               "dexador"
               "com.inuoe.jzon"
               "mcp-lisp/main")
  :in-order-to ((test-op (test-op "mcp-lisp/tests"))))

(asdf:defsystem "mcp-lisp/tests"
  :description "Tests for mcp-lisp"
  :depends-on ("mcp-lisp" "fiveam")
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
               (:file "sse-tests"))
  :perform (test-op (o c)
                    (symbol-call :fiveam :run!
                                 (find-symbol "MCP-LISP-TESTS"
                                              :mcp-lisp/tests))))

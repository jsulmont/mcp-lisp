;;;; mcp-lisp.asd

(asdf:defsystem "mcp-lisp"
  :class :package-inferred-system
  :description "Common Lisp SDK for Model Context Protocol"
  :author "Jan Dudek"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria"
               "jsonrpc"
               "bordeaux-threads"
               "cl-ppcre"
               "log4cl"
               "hunchentoot"
               "dexador"
               "com.inuoe.jzon"
               "mcp-lisp/main")
  :in-order-to ((test-op (test-op "mcp-lisp/tests"))))

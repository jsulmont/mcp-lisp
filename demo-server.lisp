;;;; demo-server.lisp
;;;; MCP server with the built-in agent tools (eval_lisp, shell, read_file, etc.)
;;;; For use with Claude Code via .mcp.json

(ql:quickload :mcp-lisp :silent t)

;; Access log to stdout so you can see what Claude does
(setf mcp-lisp/src/transport/mcp-sse:*access-log-stream* *standard-output*)

(format t "~%MCP server with agent tools on port 8080~%")
(format t "Tools: eval_lisp, shell, read_file, clear_repl, list_tools~%")
(format t "Press Ctrl-C to stop.~%~%")

(let ((server (mcp-lisp:make-server :name "mcp-lisp-demo" :version "0.1.0")))
  (mcp-lisp:server-start server :transport :sse :port 8080)
  (handler-case (loop (sleep 3600))
    (sb-sys:interactive-interrupt ()
      (format t "~%Shutting down...~%")
      (mcp-lisp:server-stop server)
      (sb-ext:exit :code 0))))

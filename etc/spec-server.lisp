;;;; etc/spec-server.lisp
;;;; Stdio MCP server for behavioral specs.
;;;; Use as a Claude Code MCP server:
;;;;   claude mcp add --scope user lisp-tools -- sbcl --noinform --load /path/to/mcp-lisp/etc/spec-server.lisp

;; Suppress all output during load — stdio transport needs clean stdout
(let ((*standard-output* (make-broadcast-stream))
      (*error-output* (make-broadcast-stream))
      (*trace-output* (make-broadcast-stream)))
  (ql:quickload :mcp-lisp :silent t))

;; Silence log4cl — no console logging for stdio transport
(log:config :off)

;; Disable debugger — exit cleanly when Claude Code disconnects
(sb-ext:disable-debugger)

(handler-case
    (mcp-lisp:run-server :name "spec-server" :version "0.1.0")
  (end-of-file ()
    (sb-ext:exit :code 0))
  (#+sbcl sb-sys:interactive-interrupt #-sbcl condition ()
    (sb-ext:exit :code 0))
  (error ()
    (sb-ext:exit :code 1)))

;;;; examples/tool-search/server.lisp
;;;;
;;;; Mock "cloud-ops" MCP server exposing 12 tools over HTTP (Streamable HTTP /
;;;; SSE). Run it in its own terminal and watch the live tool trace:
;;;;
;;;;   sbcl --load examples/tool-search/server.lisp
;;;;
;;;; Then, in another terminal, run the agent client (client.lisp / run.sh).
;;;; The client connects to http://localhost:8930/mcp, lists these tools, defers
;;;; them all, and lets the model discover them via the tool search tool.
;;;;
;;;; Each tool call is printed to THIS terminal via SLOG, so you can see exactly
;;;; what the agent invokes, in order, with arguments and results.

(let ((*standard-output* (make-broadcast-stream))
      (*trace-output* (make-broadcast-stream))
      (*error-output* *error-output*)
      (this-file (or *load-truename* *default-pathname-defaults*)))
  (let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
    (when (probe-file ql-setup)
      (load ql-setup)))
  (require :asdf)
  (let* ((examples-dir (make-pathname :directory (pathname-directory this-file)))
         (project-dir (truename (merge-pathnames "../../" examples-dir))))
    (eval `(pushnew ,project-dir ,(find-symbol "*CENTRAL-REGISTRY*" "ASDF") :test #'equal))
    ;; Muffle the library's compile-time warnings/notes (log4cl redefs, the
    ;; woo +SF-MNOWAIT+ CFFI note on macOS, define-tool unused-args). Real
    ;; errors still throw.
    (handler-bind ((warning #'muffle-warning)
                   #+sbcl (sb-ext:compiler-note #'muffle-warning))
      (funcall (find-symbol "LOAD-SYSTEM" "ASDF") :mcp-lisp :verbose nil :print nil))))

(defpackage #:tool-search-server
  (:use #:cl #:mcp-lisp/main))

(in-package #:tool-search-server)

(defparameter *port* 8930)

(defun now ()
  (multiple-value-bind (s m h) (decode-universal-time (get-universal-time))
    (format nil "~2,'0d:~2,'0d:~2,'0d" h m s)))

(defun slog (label result)
  "Print a tool call to this server's console and return RESULT unchanged."
  (format t "~a  [cloud-ops] ~a~%             => ~a~%" (now) label result)
  (force-output)
  result)

(define-tool instance-list ()
  "List all compute instances in the fleet with their current state."
  (slog "instance_list()"
        "web-1 running, web-2 running, web-3 stopped, worker-1 running, db-1 running"))

(define-tool instance-start ((instance-id string "Instance identifier, e.g. web-3" :required t))
  "Start a stopped compute instance."
  (slog (format nil "instance_start(instance_id=~a)" instance-id)
        (format nil "instance ~a starting; expected ready in ~~45s" instance-id)))

(define-tool instance-stop ((instance-id string "Instance identifier" :required t))
  "Stop a running compute instance."
  (slog (format nil "instance_stop(instance_id=~a)" instance-id)
        (format nil "instance ~a stopping" instance-id)))

(define-tool instance-metrics ((instance-id string "Instance identifier" :required t))
  "Get recent CPU and memory utilization for a compute instance."
  (slog (format nil "instance_metrics(instance_id=~a)" instance-id)
        (cond
          ((string= instance-id "web-1") "web-1: cpu 93%, mem 71%, 5m load 4.2")
          ((string= instance-id "web-2") "web-2: cpu 88%, mem 69%, 5m load 3.9")
          ((string= instance-id "web-3") "web-3: stopped, no metrics")
          (t (format nil "~a: cpu 22%, mem 40%, 5m load 0.6" instance-id)))))

(define-tool bucket-list ()
  "List object-storage buckets."
  (slog "bucket_list()" "assets-prod, backups-prod, logs-archive, user-uploads"))

(define-tool bucket-size ((bucket string "Bucket name" :required t))
  "Report the total stored size of an object-storage bucket."
  (slog (format nil "bucket_size(bucket=~a)" bucket)
        (format nil "~a: 412 GiB across 1.2M objects" bucket)))

(define-tool log-query ((service string "Service name to search logs for" :required t)
                        (pattern string "Substring or level to match, e.g. ERROR" :default "ERROR"))
  "Search recent application logs for a service."
  (slog (format nil "log_query(service=~a, pattern=~a)" service pattern)
        (format nil "~a logs matching '~a': 37 hits in last hour; top: 'upstream timeout (1200ms)'"
                service pattern)))

(define-tool alert-create ((name string "Alert name" :required t)
                           (threshold number "Trigger threshold (percent)" :required t))
  "Create a monitoring alert."
  (slog (format nil "alert_create(name=~a, threshold=~a)" name threshold)
        (format nil "alert '~a' created, fires above ~,1f%" name threshold)))

(define-tool alert-list ()
  "List configured monitoring alerts."
  (slog "alert_list()" "cpu-high (>90%), disk-low (<10%), error-rate (>5%)"))

(define-tool billing-summary ()
  "Get the current month-to-date billing summary and projection."
  (slog "billing_summary()"
        "MTD $4,213; projected $6,840. Top: compute $3,100, storage $640, egress $410"))

(define-tool service-scale ((service string "Service name" :required t)
                            (replicas number "Desired replica count" :required t))
  "Scale a service to a target replica count."
  (slog (format nil "service_scale(service=~a, replicas=~a)" service (round replicas))
        (format nil "scaling ~a to ~d replicas" service (round replicas))))

(define-tool service-health ((service string "Service name, e.g. web" :required t))
  "Get the health status of a service."
  (slog (format nil "service_health(service=~a)" service)
        (cond
          ((string= service "web")
           "web: DEGRADED, 2/3 instances healthy, p99 latency 1200ms, error rate 4.1%")
          (t (format nil "~a: HEALTHY, p99 latency 90ms, error rate 0.2%" service)))))

;; Loading mcp-lisp also registers the built-in agent tools (shell, eval_lisp,
;; read_file, ...) into the global registry. Drop everything except our 12 mock
;; tools so the server exposes a clean cloud-ops catalog.
(let ((keep '("instance_list" "instance_start" "instance_stop" "instance_metrics"
              "bucket_list" "bucket_size" "log_query" "alert_create" "alert_list"
              "billing_summary" "service_scale" "service_health")))
  (dolist (name (loop for k being the hash-keys of *global-tool-registry* collect k))
    (unless (member name keep :test #'string=)
      (unregister-tool name))))

;; Transport-level (woo/log4cl) logging goes to a file so it doesn't clutter the
;; console; the SLOG tool trace above is what you watch here.
(log4cl:clear-logging-configuration)
(log:config :daily "/tmp/tool-search-server.log" :backup nil)
(log:config :info)

(format t "~&~a  [cloud-ops] MCP server on http://localhost:~d/mcp — 12 tools, waiting for a client~%"
        (now) *port*)
(force-output)

(run-server :name "cloud-ops" :version "1.0.0" :transport :sse :port *port*)

;; run-server returns once the HTTP server is started; keep the process alive.
(loop (sleep 3600))

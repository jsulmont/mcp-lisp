;;;; profile-server.lisp
;;;; MCP server with sb-sprof statistical profiling.
;;;;
;;;; Usage:
;;;;   sbcl --load profile-server.lisp
;;;;   # In another terminal: uv run soak-test.py --concurrency 50 --interval 5
;;;;   # Ctrl-C to stop — profile report prints on exit.
;;;;
;;;; Change :mode :cpu to :mode :alloc to see where allocations happen.

(ql:quickload :mcp-lisp :silent t)
(require :sb-sprof)

;;; Register minimal fixtures — same tools/resources/prompts the soak test hits.

(mcp-lisp/src/primitives/tools/registry:register-tool
 "test_simple_text" "Returns simple text"
 (mcp-lisp/src/primitives/tools/schema:make-input-schema (make-hash-table :test #'equal) nil)
 (lambda (s ss a) (declare (ignore s ss a))
   (vector (mcp-lisp:text-content "This is a simple text response for testing."))))

(mcp-lisp/src/primitives/tools/registry:register-tool
 "test_image_content" "Returns image"
 (mcp-lisp/src/primitives/tools/schema:make-input-schema (make-hash-table :test #'equal) nil)
 (lambda (s ss a) (declare (ignore s ss a))
   (vector (mcp-lisp:make-ht "type" "image" "data" "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ" "mimeType" "image/png"))))

(mcp-lisp/src/primitives/tools/registry:register-tool
 "test_audio_content" "Returns audio"
 (mcp-lisp/src/primitives/tools/schema:make-input-schema (make-hash-table :test #'equal) nil)
 (lambda (s ss a) (declare (ignore s ss a))
   (vector (mcp-lisp:make-ht "type" "audio" "data" "UklGRiQAAABXQVZFZm10IBAAAA" "mimeType" "audio/wav"))))

(mcp-lisp/src/primitives/tools/registry:register-tool
 "test_embedded_resource" "Returns embedded resource"
 (mcp-lisp/src/primitives/tools/schema:make-input-schema (make-hash-table :test #'equal) nil)
 (lambda (s ss a) (declare (ignore s ss a))
   (vector (mcp-lisp:make-ht "type" "resource"
                              "resource" (mcp-lisp:make-ht "uri" "test://embedded" "mimeType" "text/plain"
                                                           "text" "Embedded resource content.")))))

(mcp-lisp/src/primitives/tools/registry:register-tool
 "test_multiple_content_types" "Returns mixed content"
 (mcp-lisp/src/primitives/tools/schema:make-input-schema (make-hash-table :test #'equal) nil)
 (lambda (s ss a) (declare (ignore s ss a))
   (vector (mcp-lisp:text-content "Mixed content:")
           (mcp-lisp:make-ht "type" "image" "data" "iVBORw0KGgo" "mimeType" "image/png"))))

(mcp-lisp/src/primitives/tools/registry:register-tool
 "test_error_handling" "Always errors"
 (mcp-lisp/src/primitives/tools/schema:make-input-schema (make-hash-table :test #'equal) nil)
 (lambda (s ss a) (declare (ignore s ss a))
   (error 'mcp-lisp/src/conditions:tool-error :message "Intentional error")))

(mcp-lisp/src/primitives/resources/registry:register-resource
 "test://static-text" "Static Text" "A text resource"
 (lambda (s ss) (declare (ignore s ss)) "Static text content.")
 :mime-type "text/plain")

(mcp-lisp/src/primitives/resources/registry:register-resource
 "test://static-binary" "Static Binary" "A binary resource"
 (lambda (s ss) (declare (ignore s ss)) (mcp-lisp:make-ht "blob" "iVBORw0KGgo"))
 :mime-type "image/png")

(mcp-lisp/src/primitives/resources/registry:register-resource-template
 "test://template/{id}/data" "Template" "A template resource"
 (lambda (s ss params) (declare (ignore s ss))
   (mcp-lisp:encode-json (mcp-lisp:make-ht "id" (cdr (assoc "id" params :test #'string=))
                                             "data" "template data")))
 :mime-type "application/json")

(mcp-lisp/src/primitives/prompts/registry:register-prompt
 "test_simple_prompt" "A simple prompt" nil
 (lambda (s ss a) (declare (ignore s ss a))
   (list (mcp-lisp:make-ht "role" "user"
                            "content" (mcp-lisp:make-ht "type" "text"
                                                        "text" "Simple prompt."))))
 mcp-lisp/src/primitives/prompts/registry:*global-prompt-registry*)

(mcp-lisp/src/primitives/prompts/registry:register-prompt
 "test_prompt_with_arguments" "A prompt with args"
 (list (mcp-lisp:make-ht "name" "arg1" "description" "First arg" "required" t)
       (mcp-lisp:make-ht "name" "arg2" "description" "Second arg" "required" t))
 (lambda (s ss a) (declare (ignore s ss))
   (list (mcp-lisp:make-ht "role" "user"
                            "content" (mcp-lisp:make-ht "type" "text"
                                                        "text" (format nil "arg1=~a arg2=~a"
                                                                       (gethash "arg1" a)
                                                                       (gethash "arg2" a))))))
 mcp-lisp/src/primitives/prompts/registry:*global-prompt-registry*)

;;; Start server with profiling

(setf mcp-lisp/src/transport/mcp-woo:*access-log-stream* nil)

(format t "~%Starting profiled MCP server on port 8080...~%")
(format t "Hit it with: uv run soak-test.py --concurrency 50~%")
(format t "Ctrl-C to stop and see profile report.~%~%")

(let ((server (mcp-lisp:make-server :name "mcp-lisp-profiled" :version "0.1.0"))
      (stop nil))
  (mcp-lisp:server-start server :transport :sse :port 8080)

  (sb-sprof:start-profiling :mode :cpu :sample-interval 0.001 :threads :all)

  ;; SIGINT may arrive on the Woo event-loop thread (inside kqueue/select),
  ;; not the main thread.  Use enable-interrupt so the handler runs in
  ;; whichever thread receives the signal.
  (sb-sys:enable-interrupt sb-unix:sigint
    (lambda (signal info context)
      (declare (ignore signal info context))
      (setf stop t)))

  (loop until stop do (sleep 0.5))

  (sb-sprof:stop-profiling)
  (format t "~%~%=== CPU Profile (flat, top 40) ===~%~%")
  (sb-sprof:report :type :flat :max 40)
  (finish-output)
  (mcp-lisp:server-stop server)
  (sb-ext:exit :code 0))

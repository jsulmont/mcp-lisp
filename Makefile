.PHONY: test load clean

test:
	sbcl --non-interactive \
		--eval '(ql:quickload :mcp-lisp/tests :silent t)' \
		--eval '(mcp-lisp/tests:run-tests)'

load:
	sbcl --eval '(ql:quickload :mcp-lisp)'

clean:
	find . -name '*.fasl' -delete

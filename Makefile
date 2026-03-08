EMACS ?= emacs

SRCS := emacs-todoist-org.el emacs-todoist-api.el emacs-todoist.el \
	emacs-todoist-frontend.el emacs-todoist-org-capture.el
TEST_SRCS := $(wildcard tests/test-*.el)

.PHONY: test test-org test-api test-integration test-frontend test-live compile clean

compile:
	$(EMACS) --batch -L . -f batch-byte-compile $(SRCS)

test:
ifdef FILE
ifdef MATCH
	$(EMACS) --batch -L . -L tests -l $(FILE).el \
	  --eval '(ert-run-tests-batch-and-exit "$(MATCH)")'
else
	$(EMACS) --batch -L . -L tests -l $(FILE).el \
	  -f ert-run-tests-batch-and-exit
endif
else
	$(EMACS) --batch -L . -L tests -l run-tests.el \
	  -f ert-run-tests-batch-and-exit
endif

test-org test-api test-integration test-frontend test-live: test-%:
ifdef MATCH
	$(EMACS) --batch -L . -L tests -l test-$*.el \
	  --eval '(ert-run-tests-batch-and-exit "$(MATCH)")'
else
	$(EMACS) --batch -L . -L tests -l test-$*.el \
	  -f ert-run-tests-batch-and-exit
endif

clean:
	rm -f *.elc tests/*.elc

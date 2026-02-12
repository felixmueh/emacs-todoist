EMACS ?= emacs

SRCS := emacs-todoist-org.el emacs-todoist-api.el emacs-todoist.el
TEST_SRCS := $(wildcard tests/test-*.el)

.PHONY: test test-org test-api test-integration compile clean

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

test-org:
	$(EMACS) --batch -L . -L tests -l test-org.el \
	  -f ert-run-tests-batch-and-exit

test-api:
	$(EMACS) --batch -L . -L tests -l test-api.el \
	  -f ert-run-tests-batch-and-exit

test-integration:
	$(EMACS) --batch -L . -L tests -l test-integration.el \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc tests/*.elc

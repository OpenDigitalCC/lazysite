.PHONY: test test-unit test-integration test-smoke test-journey test-safety test-verbose

test:
	prove -r t/

test-unit:
	prove -r t/unit/

test-integration:
	prove -r t/integration/

test-smoke:
	prove -r t/smoke/

test-journey:
	prove -r t/journey/

test-safety:
	prove t/unit/processor/14-process-safety.t t/unit/processor/15-cache-safety.t

test-verbose:
	prove -rv t/

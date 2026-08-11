.PHONY: test test-unit test-integration test-smoke test-journey test-safety test-verbose \
        tier-dev tier-review tier-release tiers

test:
	prove -r t/

# --- SM269 phase 2: the tier ladder -----------------------------------------
#
# Which tests to run WHEN, with one answer per situation. The tiers are named
# after the moment they belong to, not after what they contain, because "which
# directory" is the question people get wrong.
#
# Measured (SM269 phase 0/1, on 6 cores): the full plain suite is ~330s
# sequential and ~122s at -j4; the release gate is ~80 minutes, of which
# coverage is 92%. So the ladder is not an optimisation of the gate - it exists
# so a problem surfaces while the code is being written rather than at the cut.

# DEV - seconds. Every edit. Lint plus the area you touched:
#   make tier-dev AREA=manager
#
# -l on every target, not just the release one: without it the tests that load
# Lazysite:: modules die with 0 tests run, and `prove -r` reports that as a
# failure with no cause on screen. The full suite has always used -lr; a tier
# that omits it fails for a reason that has nothing to do with the code.
tier-dev:
	prove -lj4 t/lint/04-compile.t t/lint/06-tidy.t
ifeq ($(strip $(AREA)),)
	@echo "  (set AREA=<manager|processor|users|mcp|dav|auth|lib|plugins> to add that area)"
else
	prove -lj4 -r t/unit/$(AREA)/
endif

# REVIEW - ~2 minutes. Branch handoff. The whole plain suite in parallel.
# Phase 1 made this safe: prove -j4 is green on 321 files.
tier-review:
	prove -lr -j4 t/

# RELEASE - ~80 minutes. Once per cut, and NOT a subset of anything:
# suite, then bench, then coverage against the declared floor.
tier-release:
	prove -lr t/
	perl tools/bench.pl --check
	bash tools/coverage.sh --check

tiers:
	@echo "tier-dev      seconds   every edit      lint + AREA=<area>"
	@echo "tier-review   ~2 min    branch handoff  full suite at -j4"
	@echo "tier-release  ~80 min   once per cut    suite + bench + coverage"
	@echo ""
	@echo "There is no scheduled tier yet: SM269 phase 3 has to justify one"
	@echo "by emitting a worklist somebody uses. Measurement without a"
	@echo "consumer is not a tier."

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

.PHONY: test test-unit test-integration test-smoke test-journey test-safety test-verbose \
        tier-dev tier-precheck tier-review tier-release tiers handoff

# The whole plain suite: through tools/suite.sh, one run at a time (SM1061).
test:
	bash tools/suite.sh

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

# PRECHECK - lints + the tests naming a changed file + the tests of each area it
# touches (SM949, SM1061): the handoff's test run, minutes
tier-precheck:
	bash tools/precheck.sh

# REVIEW - the whole plain suite, through tools/suite.sh: -j<nproc>, and one
# whole-suite run at a time on the host (SM1061). Run on demand, by `handoff
# --full`/`--release`, and nightly; not by a default handoff.
tier-review:
	bash tools/suite.sh

# HANDOFF - the precheck on each branch plus the review's tripwires; prints the
# READY line a branch is offered for review with (SM764, SM1061). `make handoff
# FULL=1` adds the whole suite; `RELEASE=1` the suite and the bench gate.
handoff:
	bash tools/handoff.sh $(if $(RELEASE),--release,$(if $(FULL),--full,))

# RELEASE - ~80 minutes. Once per cut, and NOT a subset of anything:
# suite, then bench, then coverage against the declared floor.
tier-release:
	bash tools/suite.sh
	perl tools/bench.pl --check
	bash tools/coverage.sh --check

tiers:
	@echo "tier-dev      seconds   every edit      lint + AREA=<area>"
	@echo "tier-precheck minutes   each commit     lints + tests naming changed files + their areas"
	@echo "tier-review   ~18 min   on demand       full suite via tools/suite.sh (host lock)"
	@echo "handoff       ~1 min    before review   precheck + tripwires; prints READY (SM1061)"
	@echo "tier-release  ~80 min   once per cut    suite + bench + coverage"
	@echo "nightly      ~20 min   00:30           tools/suite.sh --nightly on main; inbox on failure"
	@echo ""
	@echo "The whole suite is on demand (tools/suite.sh), required for a release, and"
	@echo "nightly as a safety net; the handoff runs the precheck (SM1061)."

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

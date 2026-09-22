test:
	protoconf mod tidy
	protoconf compile .
	$(MAKE) gates

# The fixture's pipeline stays under outputs/ and is never installed at the repository root:
# its S3 backend is a placeholder no runner can reach, so it is drift-checked, not run.

# The two compile gates in the CI driver are the only thing standing between a component and
# a Terraform state CI throws away on every apply. Nothing above this target defends them:
# `protoconf compile .` only ever compiles inputs that are correct, so deleting either
# _check_remote_backends or _check_reads_are_produced from TerraformPipeline leaves the whole
# build green — measured, not assumed. This target is the missing half: it feeds each gate the
# wiring that gate exists to reject, and fails if the gate stays quiet.
#
# It decides "the gate fired" from the gate's own message AND from the function named in the
# compiler traceback, never from the exit code. Both mutations exit non-zero even with the
# gates removed — the local-backend one collapses two states onto one id and trips the
# duplicate-state fail() in _producers, the mismatched one trips this fixture's own ordering
# assertion — so an exit-code check would report a deleted gate as firing.
#
# Each substitution is confirmed to have landed in the copy before the resulting compile is
# interpreted. A fixture edit that breaks an anchor produces a copy identical to the original,
# which compiles clean, which is indistinguishable from a gate that stopped firing.
#
# The tracked fixture is never the file being mutated: the mutations are written to copies
# under src/, and a trap removes them on every exit path, so an interrupted run leaves
# src/handshake_test.mpconf byte-identical and nothing to restore.
gates:
	@set -e; \
	log=$$(mktemp); \
	trap 'rm -f src/gate04_probe.mpconf src/gate05_probe.mpconf "$$log"' EXIT; \
	sed 's/^NEAR_BACKEND = BACKEND$$/NEAR_BACKEND = LOCAL/' src/handshake_test.mpconf > src/gate04_probe.mpconf; \
	grep -q '^NEAR_BACKEND = LOCAL$$' src/gate04_probe.mpconf || { \
		echo "gates: FOUND-04 substitution did not land in src/gate04_probe.mpconf — check that test/src/handshake_test.mpconf:64 still reads exactly 'NEAR_BACKEND = BACKEND' on its own line"; \
		exit 1; \
	}; \
	protoconf compile . gate04_probe.mpconf > "$$log" 2>&1 || true; \
	grep -q 'writes local Terraform state' "$$log" && grep -q '_check_remote_backends' "$$log" || { \
		echo "gates: FOUND-04 gate did not fire — _check_remote_backends did not report a local backend"; \
		cat "$$log"; \
		exit 1; \
	}; \
	sed 's/^FAR_BACKEND = BACKEND$$/FAR_BACKEND = MISMATCHED/' src/handshake_test.mpconf > src/gate05_probe.mpconf; \
	grep -q '^FAR_BACKEND = MISMATCHED$$' src/gate05_probe.mpconf || { \
		echo "gates: FOUND-05 substitution did not land in src/gate05_probe.mpconf — check that test/src/handshake_test.mpconf:70 still reads exactly 'FAR_BACKEND = BACKEND' on its own line"; \
		exit 1; \
	}; \
	protoconf compile . gate05_probe.mpconf > "$$log" 2>&1 || true; \
	grep -q 'which no config in this pipeline writes' "$$log" && grep -q '_check_reads_are_produced' "$$log" || { \
		echo "gates: FOUND-05 gate did not fire — _check_reads_are_produced did not report a read of an unproduced state"; \
		cat "$$log"; \
		exit 1; \
	}; \
	echo "gates: both compile gates fired"

.PHONY: test workflows gates

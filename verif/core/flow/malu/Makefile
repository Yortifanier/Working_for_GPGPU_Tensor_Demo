PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../../..)
.PHONY: check check1 check2 check3 lint
check:
	cd "$(PROJECT_ROOT)" && python3 tools/run_malu_checks.py --round all
check1:
	cd "$(PROJECT_ROOT)" && python3 tools/run_malu_checks.py --round 1
check2:
	cd "$(PROJECT_ROOT)" && python3 tools/run_malu_checks.py --round 2
check3:
	cd "$(PROJECT_ROOT)" && python3 tools/run_malu_checks.py --round 3
lint:
	cd "$(PROJECT_ROOT)" && python3 tools/run_malu_checks.py --lint-only

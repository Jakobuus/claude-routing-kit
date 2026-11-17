#!/bin/bash
# Runs the python unit tests for board_dm delivery races (tests/run only picks up .sh files).
cd "$(dirname "$0")/.." || exit 1
. plugins/routing-kit/bin/kit-common
if kit_python3 tests/test_board_dm_unit.py >/dev/null 2>&1; then echo 'PASS 1 / FAIL 0'; else kit_python3 tests/test_board_dm_unit.py; echo 'PASS 0 / FAIL 1'; exit 1; fi

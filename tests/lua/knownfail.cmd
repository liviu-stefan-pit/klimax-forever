@echo off
rem Runs the phase 18 KNOWN FAILING specs (tests/lua/known_failing_spec.lua). They encode the
rem correct behaviour for the level 15 Hunter report and are EXPECTED TO FAIL on the legacy engine
rem until phases 20 and 21. Run from the repo root. Extra arguments go to busted.
set "KLIMAX_KNOWNFAIL=1"
call "%~dp0busted.cmd" tests/lua/known_failing_spec.lua %*

extends GutTest
## [RuntimeMode] is the guard that keeps the suite free to run.
##
## If these two tests ever fail, every other test in the project has become capable of
## spending real money, so they are worth stating explicitly rather than assuming.


func test_a_gut_run_is_detected_as_a_test_run() -> void:
	assert_true(
		RuntimeMode.is_test_run(),
		"GUT's runner should be visible on the command line",
	)


func test_a_test_run_is_offline() -> void:
	assert_true(RuntimeMode.is_offline(), "a test run must forbid outbound requests")

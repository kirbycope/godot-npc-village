class_name RuntimeMode
extends RefCounted
## Decides whether this process is allowed to talk to the network.
##
## Both paid services in this project check [method is_offline] before their first
## request, so a test run cannot reach the Claude API or ElevenLabs no matter what a
## test does. That is not only about continuous integration having no credentials. Both
## APIs are metered against a real account: the dialogue model bills per token and a
## free ElevenLabs plan allows ten thousand characters a month in total. A suite that
## called out would charge the account on every commit, which is intolerable for
## something meant to run constantly.
##
## The tests are therefore built entirely on recorded fixtures under `tests/fixtures/`,
## and this class is the backstop that keeps them honest.
##
## Offline is chosen when any of these hold:
##
## - The build is running in a browser. A web build ships no keys, because anything
##   inside a `.pck` is a download and therefore public, and asking a visitor to paste
##   their own key into a web page is asking them to expose a credential. So the web
##   build never calls out: it plays the committed voice bank and the villagers speak
##   their authored opening lines, which is what that bank was baked for.
## - `NPC_VILLAGE_OFFLINE` is set to `1` in the environment, which is how a build
##   machine or a developer pins it deliberately.
## - GUT's command line runner is the script being run, which covers every test run
##   without anyone having to remember to set anything.

## The environment variable that forces offline mode.
const OFFLINE_ENV: String = "NPC_VILLAGE_OFFLINE"

## Substring identifying GUT's headless runner on the command line.
const GUT_RUNNER: String = "gut_cmdln.gd"


## Whether outbound requests are forbidden in this process.
static func is_offline() -> bool:
	if OS.has_feature("web"):
		return true
	if OS.get_environment(OFFLINE_ENV) == "1":
		return true
	return is_test_run()


## Whether this process is a GUT run.
static func is_test_run() -> bool:
	for argument: String in OS.get_cmdline_args():
		if argument.contains(GUT_RUNNER):
			return true
	return false

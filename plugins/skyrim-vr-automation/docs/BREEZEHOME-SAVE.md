# Maintained Breezehome save

Until the automated New Game path is robust enough to be the default, the
maintained base MO2 profile provides a known-good save inside Whiterun
Breezehome.

The portable fixture ID is `breezehome-interior`. Create a task profile with
`-SavePolicy VerifiedFixture -FixtureId breezehome-interior` when the task is
authorized to load this exact baseline. The `create` result reports the current
exact save selector as `data.saveFixture.loadName` and its human-readable
location as `data.saveFixture.location`. Use those returned values rather than
hard-coding a save filename, because maintaining the base profile may replace
the underlying save.

Every newly created task profile receives a verified copy of the complete
`saves` tree from `defaults.testProfileSource`, regardless of `SavePolicy`.
`MainMenuOnly` still forbids loading any save, and `FreshGame` still requires a
genuine New Game path; copying saves does not broaden either authorization.

Before relying on the Breezehome baseline, run `fixture-status`. A result of
`fixture-valid` confirms that the declared Breezehome `.ess` and matching
co-save exist and match their recorded hashes. If it is stale, repair the
maintained base profile or use the guarded `refresh-fixture` workflow before
creating the task profile.

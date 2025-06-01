require Logger

Application.put_env(:oci, TestRegistryWeb.Endpoint,
  http: [port: 4002],
  server: true
)

{:ok, _pid} = TestRegistryWeb.Endpoint.start_link()
Logger.info("🤞 Phoenix endpoint started for conformance tests")

:ok =
  ConformanceSuite.clone_repo(
    "https://github.com/coryodaniel/distribution-spec.git",
    "fix/patch-content-range-requirement-in-02-setup",
    force: false
  )

:ok = ConformanceSuite.build(force: true)

ConformanceSuite.generate_report()

{:ok, _} = Application.ensure_all_started(:oci)

# The tests are actually run outside of exunit, but the results are evaluated and printed.
# Order is forced to make it easier to work through what is off from the conformance spec
# Since those conformance tests _are_ run in order and depend on each other to build up state.
ExUnit.configure(seed: 0)
ExUnit.start()

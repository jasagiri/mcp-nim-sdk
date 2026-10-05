# External specifications

What the SDK does as seen from outside, one Scenario per observable fact.

- `*.feature`: Gherkin. Each Scenario has `@spec:MCP-<AREA>-<n>`, the identifier of the specification.
  - `@feature:ftXxx` ties it to a row of `src/protocol/features.nim`: the Scenario holds for the protocol versions that have the feature. Without it, it holds for every version.
  - `@unimplemented` marks a Scenario for something the SDK does not do yet. It is a statement of intent, not a test; no test may be listed for it.
- `tests.map`: `ID | test file | test name`, one line per test that verifies a Scenario.

`tests/test_spec_coverage.nim` checks that every specification without `@unimplemented` has at least one test in `tests.map`, that each listed test exists under exactly that name, that no identifier is repeated, and that `@feature` agrees with `src/protocol/implementation_status.nim`.

There is no Gherkin runner here (it would be a new dependency); the Scenarios are the statement of the specification and the listed tests are what executes it.

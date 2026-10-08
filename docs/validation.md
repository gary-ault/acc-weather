# Temperature-only validation

Version: 0.2.0. Rebuild date: 2026-10-07 (America/Chicago).

The two temperature scripts from source commit `a3726ac` are preserved unchanged.
The bin directory, manifest and allow list are restricted to those scripts.

## Automated checks

Local Windows Ruby 3.3.12 result: **14 tests, 183 assertions, zero failures or
errors**. Unsigned archive validation passed; the signed build's signature was
verified and its inner payload matched the tested unsigned archive byte for byte.

`ruby test/temperature_test.rb` executes the actual scripts in child Ruby
processes, intercepting HTTP only in the test process. It covers high/low
inclusive thresholds, critical precedence, station normalization and endpoint,
exact metric output and observation timestamp, zero/negative temperatures,
required parameters, threshold ordering, unsupported metric arguments, missing
temperature, bad JSON/timestamps, HTTP 429/503 and timeout failures. Assertions
check actual process exit codes and empty stdout on errors.

`python test/package_test.py` verifies that the source bin directory and manifest
contain exactly the two scripts, archive files match current source bytes,
executable modes are correct, and the allow list contains only those entry points.

The signed build verifies its signature with the public certificate. Its inner
archive must exactly match the tested unsigned archive.

GitHub Actions runs tests and package validation on Windows and Linux with Ruby
3.2 and 3.3. Consult Actions for results at the current commit.

## Limits

There is no deployed ACC agent or ServiceNow instance in this workspace.
Certificate trust, embedded-Ruby invocation, platform filters, target CI routing
and metric ingestion require endpoint acceptance. This rebuild preserves the
supplied scripts' HTTP, freshness and exception behavior as documented in the
configuration guide.

# Validation record

Initial local validation: 2026-10-05 UTC (2026-10-04 America/Chicago).

- Windows portable Ruby 3.3.12: 17 tests, 147 assertions, zero failures/errors.
- Tests cover nearest-station selection, distance limits, station overrides,
  all supported input/output wind units, inclusive warning/critical boundaries,
  explicit calm wind, missing/invalid values, stale/future timestamps, HTTP errors,
  timeouts, TLS settings, malformed JSON, metric stdout isolation, CLI validation,
  and real entry-point help/failure exit codes.
- Unsigned archive contents, source bytes, executable modes and allow list passed
  `python test/package_test.py`.
- Actual NWS point/station/observation requests succeeded through the new Ruby
  code at the public example coordinates `39.7456,-97.0892`.
- Selected station: KMYZ, approximately 41.0 km from that point.
- Observation: `2026-10-05T01:35:00Z`, sustained wind `3.355404 mph`.

Actual metric stdout:

```text
weather.nws_example.wind_speed_mph 3.355404 1791164100
```

Actual event output with deliberately low **test-only** thresholds:

```text
CRITICAL - ci=nws_example wind_speed=3.36 mph warning=1 critical=2 station=KMYZ distance=41.0km observed=2026-10-05T01:35:00Z age=40.1min
```

No ServiceNow instance or deployed ACC agent was available for integration testing.
Instance plugin filters, the agent's embedded Ruby launch behavior, certificate
trust, and data center CI association still require endpoint acceptance testing.
The GitHub workflow separately tests ordinary Ruby on Windows and Linux; see
Actions for the result at the current commit.

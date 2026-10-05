# ACC Weather

One Ruby weather plugin for ServiceNow Agent Client Collector on Windows and Linux.
Version 0.1.0 monitors the latest **observed sustained wind speed** near a data
center. It does not collect gusts, forecasts, watches, or warnings.

| Script | ACC check type | Output |
| --- | --- | --- |
| `check_weather_wind.rb` | Event | OK / WARNING / CRITICAL / UNKNOWN and diagnostic context |
| `metrics_weather_wind.rb` | Metrics | One Graphite line for wind speed; no thresholds |

Both scripts share `weather_lib.rb` and run with ACC's bundled Ruby. No external
gems, curl, PowerShell, Bash, or VBScript are needed at runtime. Target Ruby 3.2+.
Python 3.10+ is needed only to build packages. Tests use Minitest, a development
dependency included in the tested Ruby distributions.

## Inputs and data

Resolve the data center CI's referenced location in ServiceNow and pass its
latitude, longitude, and CI identifier. The scripts do not query the CMDB.
By default, they resolve `/points/{lat},{lon}`, get its `observationStations`
collection, select the geographically nearest station in that collection, then
read `/stations/{stationId}/observations/latest` and `properties.windSpeed`.
Distance is straight-line distance, not a guarantee of representative conditions.
An optional station override supports a reviewed, stable station choice.

Required inputs are `--latitude`, `--longitude`, `--ci-id`, and `--user-agent`.
The event check also requires `--warning` and `--critical`; there are no default
weather thresholds. Limits are inclusive and critical takes precedence. Critical
must be greater than warning. Thresholds use the selected output unit.

Defaults: mph, maximum observation age 90 minutes, maximum station distance 50 km,
and 10 seconds per HTTP request. These are configurable operational defaults, not
NWS safety criteria. Select an age limit consistent with the station's reporting
cadence. A future timestamp beyond five minutes, unavailable wind, unknown units,
invalid coordinates, HTTP errors, or stale data return UNKNOWN (exit 3).
Zero is accepted only when explicitly reported by NWS. A failed metric check
writes diagnostics to stderr and emits no measurement to stdout.

## Examples

These are public NWS example coordinates, not a configured customer facility.
The event thresholds below are illustrative only.

```sh
ruby plugins/acc-weather/bin/check_weather_wind.rb --latitude 39.7456 --longitude -97.0892 --ci-id dc_example --user-agent "acc-weather/0.1.0 (your-operations-contact)" --warning 25 --critical 40
ruby plugins/acc-weather/bin/metrics_weather_wind.rb --latitude 39.7456 --longitude -97.0892 --ci-id dc_example --user-agent "acc-weather/0.1.0 (your-operations-contact)"
```

Run `--help` on either script for all options. On an endpoint, use the ACC
embedded Ruby executable in place of a separately installed `ruby`.

Metric shape:

```text
weather.<ci-id>.wind_speed_mph <value> <observation-unix-timestamp>
```

Other suffixes: `wind_speed_kph`, `wind_speed_mps`, `wind_speed_knots`. Only one
metric is emitted per run. The timestamp represents the observation, not the poll.
Repeated polls of the same observation therefore retain the same timestamp.
The CI ID in the metric name does not itself bind the metric to a ServiceNow CI;
configure the target/proxy association as described in the deployment guide.

## Build and test

```sh
ruby test/weather_test.rb
python tools/package_plugin.py --plugin acc-weather
python test/package_test.py
```

Convenience commands: `build-plugin.bat unsigned` on Windows or
`sh build-plugin.sh unsigned` on Linux. Unsigned builds are for inspection.
For a signed package and a locally generated test certificate:

```sh
python tools/package_plugin.py --plugin acc-weather --create-signing-key
```

This creates a private signing key under `.keys/`, verifies the signature, and
exports the signed bundle, inner archive, base64 signature, and public certificate
under `dist/`. Neither `.keys/` nor `dist/` is checked into Git. For organizational
signing, pass `--signing-key PATH --signing-cert PATH` instead. Never upload a
private key. Import the public signing certificate using your ACC trust procedure
before deploying a self-signed build; do not disable signature verification.

One source tree and one payload archive serve both platforms. `plugin.json` is
local build metadata; instance platform filters and launch configuration are set
in ServiceNow. If a release requires OS-specific plugin records, attach the same
payload to those records rather than maintaining separate implementations.

GitHub Actions runs tests and unsigned package validation on Windows and Linux
with Ruby 3.2 and 3.3. This validates portable Ruby execution, not ACC installation.
See [deployment](docs/servicenow-configuration.md) and
[validation results](docs/validation.md) for integration limits and evidence.

## References

- [NWS API](https://www.weather.gov/documentation/services-web-API)
- [NWS OpenAPI schema](https://api.weather.gov/openapi.json)
- [ServiceNow ACC plugins](https://www.servicenow.com/docs/r/it-operations-management/agent-client-collector/acc-assets.html)
- [ServiceNow ACC installation](https://www.servicenow.com/docs/r/it-operations-management/agent-client-collector/acc-installation.html)

Packaging is adapted from the owner's existing Custom Linux ACC Plugin project;
the Graphite output convention follows ACC_AIX_Proxy. This is a ServiceNow ACC
plugin, not a Codex plugin.

# ACC Weather

Version **0.2.0** is a temperature-only ServiceNow Agent Client Collector plugin
for Windows and Linux. Its `bin` folder and built payload contain exactly two
standalone Ruby scripts:

| Script | ACC check type | Output |
| --- | --- | --- |
| `check_weather_temperature.rb` | Event | Temperature compared with warning/critical thresholds |
| `metrics_weather_temperature.rb` | Metrics | One `weather.temperature_c` Graphite metric |

Both query `https://api.weather.gov/stations/{STATION}/observations/latest`.
They take an NWS station ID, convert it to uppercase, and read
`properties.temperature.value`. Values and thresholds are Celsius. There is no
shared helper, location lookup, CI parameter, unit-selection parameter, or
automatic station selection. Supply a station appropriate to the monitored site.

The scripts use Ruby standard libraries and can run with ACC's embedded Ruby.
No additional runtime gems or shell wrappers are packaged. See the
[ServiceNow configuration guide](docs/servicenow-configuration.md) for setup.

## Event check

```sh
ruby plugins/acc-weather/bin/check_weather_temperature.rb --station KSJC -w 30 -c 35 --above
ruby plugins/acc-weather/bin/check_weather_temperature.rb --station KSJC -w 5 -c 0 --below
```

Thresholds above are examples, not operational recommendations.

- `--station`: required NWS station identifier.
- `-w`: required warning threshold in Celsius.
- `-c`: required critical threshold in Celsius.
- `--above`: warning at or above `-w`, critical at or above `-c`; requires `-c > -w`.
- `--below`: warning at or below `-w`, critical at or below `-c`; requires `-c < -w`.

Choose exactly one direction. Critical takes precedence. Successful evaluations
exit 0 (OK), 1 (WARNING), or 2 (CRITICAL). Example output:

```text
WARNING - temperature=32.0C station=KSJC mode=above warning=30.0 critical=35.0
```

## Metric check

```sh
ruby plugins/acc-weather/bin/metrics_weather_temperature.rb --station KSJC
```

This check accepts only the station argument and emits one line:

```text
weather.temperature_c 21.75 1791374400
```

The Unix timestamp comes from the observation, not polling time. The metric name
does not contain a station or CI ID; use separate target/check context in
ServiceNow for each facility to prevent unrelated series from being combined.

## Current script behavior

The two supplied temperature scripts are preserved unchanged. Missing parameters,
HTTP errors, missing temperature, parsing errors, and request errors raise Ruby
exceptions: exit 1 with diagnostics on stderr and no normal stdout result. This
is also the numeric exit code used for a threshold WARNING, not an UNKNOWN code.
The metric check does not invent a zero when temperature is missing.

The scripts do not set an application-specific NWS User-Agent or explicit HTTP
timeouts, validate the returned temperature unit, or check observation freshness.
Configure an outer ACC timeout. NWS requires application identification, so an
identifying User-Agent still needs to be added before production use. This
repackaging preserves the supplied scripts rather than changing those behaviors.

## Build and test

Development requirements: Python 3.10+ for packaging, Ruby 3.2/3.3 and Minitest for
tests. No development dependencies are included in the runtime archive.

```sh
ruby test/temperature_test.rb
python tools/package_plugin.py --plugin acc-weather
python test/package_test.py
```

Tests run the actual scripts in child Ruby processes with controlled NWS
responses; ordinary CI tests make no external API calls. GitHub Actions performs
these checks on Windows and Linux with Ruby 3.2 and 3.3.

Unsigned: `build-plugin.bat unsigned` or `sh build-plugin.sh unsigned`.
Output: `dist/acc-weather.tar.gz` (inspection/testing only).

Signed: `build-plugin.bat signed` or `sh build-plugin.sh signed`.
Output: `dist/signed/acc-weather.tar.gz`, accompanied by the inner archive,
base64 signature, and public signing certificate `sign.crt`.

To use an organizational certificate:

```sh
python tools/package_plugin.py --plugin acc-weather --output-dir dist/signed --signing-key PATH_TO_KEY --signing-cert PATH_TO_CERT
```

The convenience signed build reuses `.keys/` or creates a local test key and
certificate. Signing requires Python `cryptography`; OpenSSL can also perform the
signing operation. Private keys and build output are excluded from Git. Import the
public certificate using the ACC trust procedure; retain signature verification.

One payload serves both operating systems. The manifest is local build metadata;
configure compatible platform filters and Ruby execution on the instance.
See [validation](docs/validation.md) for verification scope.

## References

- [NWS API](https://www.weather.gov/documentation/services-web-API)
- [ServiceNow ACC plugins](https://www.servicenow.com/docs/r/it-operations-management/agent-client-collector/acc-assets.html)

Packaging follows the owner's existing Custom Linux ACC Plugin project.
This is a ServiceNow ACC plugin, not a Codex plugin.

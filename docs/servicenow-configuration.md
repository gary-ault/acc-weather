# Temperature check configuration

## Plugin

Register `acc-weather` version 0.2.0, display name Weather, and upload
`dist/signed/acc-weather.tar.gz`. Trust its public signing certificate through the
normal ACC procedure. Configure Windows and Linux applicability in your instance;
the local build manifest does not configure instance platform filters.

The payload contains only:

```text
allow_list/check-allow-list.json
bin/check_weather_temperature.rb
bin/metrics_weather_temperature.rb
```

The temperature scripts are unchanged from the owner's supplied source. Remove
superseded check definitions/dependencies from active policies during migration.

## Definitions

| Setting | Event | Metric |
| --- | --- | --- |
| Suggested name | `weather.check-temperature` | `weather.metrics-temperature` |
| Type | Event | Metrics |
| Plugin dependency | `acc-weather` | `acc-weather` |
| Command prefix | `check_weather_temperature.rb` | `metrics_weather_temperature.rb` |
| Exec mode | execv | execv |
| Initial interval | 600 seconds | 600 seconds, staggered |
| Suggested outer timeout | 60 seconds | 60 seconds |

| Parameter | Event | Metric |
| --- | --- | --- |
| `--station STATION` | Required | Required |
| `-w VALUE` | Required, Celsius | Unsupported |
| `-c VALUE` | Required, Celsius | Unsupported |
| `--above` | Select for high temperature | Unsupported |
| `--below` | Select for low temperature | Unsupported |

Direction flags take no value. Supply exactly one: the script accepts both but
the last one wins, so prevent that ambiguous configuration in the definition.
Above mode requires critical greater than warning; below requires critical less
than warning. There are no threshold defaults.

Example command shapes with illustrative thresholds:

```text
check_weather_temperature.rb --station KSJC -w 30 -c 35 --above
check_weather_temperature.rb --station KSJC -w 5 -c 0 --below
metrics_weather_temperature.rb --station KSJC
```

Separate event check instances may use the same script for high and low limits.

## Execution and allow list

Follow a working embedded-Ruby `.rb` check on your deployed ACC version. Do not
rely on Windows file associations. Standalone tests can invoke the full embedded
Ruby executable path followed by the full script path.

The bundled allow list names only the two scripts, permits variable arguments,
and disables shell execution. Merge its entries into the configured agent allow
list, preserving unrelated entries. Remove superseded plugin entries once unused.
If your ACC release needs an explicit interpreter command, generate the matching
allow-list entry from that definition; do not allow arbitrary Ruby execution.

## Data center CI and metric identity

Choose a suitable NWS station per data center and pass its ID through ServiceNow.
These scripts do not query the CMDB or accept coordinates. Site coordinates can
inform station selection outside the plugin.

Configure ACC target/proxy association so results bind to the data center CI,
rather than the executing host. This does not happen automatically in the scripts.
The executing agent requires outbound HTTPS to `api.weather.gov`.

Metric format: `weather.temperature_c <Celsius-value> <observation-epoch-seconds>`.
Set display units to Celsius. Keep each station/facility in separate target/check
context: the metric name is identical for every station. Repeated observations
retain their original timestamp.

## Result semantics and acceptance

Event evaluations exit 0 OK, 1 WARNING, or 2 CRITICAL. The metric check exits 0
after emitting one measurement. Both scripts raise exceptions for request or
validation errors, exit 1, and write diagnostics to stderr with no normal stdout
result. They do not return UNKNOWN/3 for such errors. Account for exit 1 being
shared by exceptions and threshold WARNING when handling failed execution.

The scripts do not enforce freshness, inspect `unitCode`, set an identifying NWS
User-Agent, or configure explicit HTTP timeouts. Configure an outer ACC timeout;
an application-specific User-Agent still needs to be added for NWS compliance.
No helper or wrapper is packaged to alter the supplied script behavior.

On a Windows and a Linux test agent, verify delivery, certificate trust, Ruby
launch, allow-list matching, outbound TLS, event routing and metric ingestion.
Confirm the correct data center CI receives results. Use temporary thresholds
for OK/WARNING/CRITICAL and an invalid station to observe failure behavior.
Standalone tests and archive checks do not replace instance acceptance testing.

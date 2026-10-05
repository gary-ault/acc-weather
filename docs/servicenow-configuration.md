# ServiceNow configuration

## Plugin registration and runtime

Upload the signed `dist/acc-weather.tar.gz` as the Weather plugin payload, version
0.1.0. Configure platform applicability to cover the intended Windows and Linux
agents using the choices supported by your instance. Local `os: all` manifest
metadata does not automatically configure instance filters. The scripts contain
no native binaries, gems, or OS-specific runtime commands.

Follow the embedded-Ruby execution convention of an existing working `.rb` check
on your deployed ACC version. Typical ACC command prefixes are the script names
below. Direct standalone tests can explicitly invoke the full embedded Ruby path
with the full script path. Do not depend on Windows `.rb` file associations.
If your ACC installation requires an explicit interpreter command, generate the
allow-list entry for that exact interpreter-plus-script command. Never allow
arbitrary `ruby -e` execution to make a check work.

The supplied allow list permits only the two script entry points, in exec mode,
with variable arguments. The library is not an allowed command. Merge entries
into the configured allow list; do not replace existing entries. If your release
matches commands differently, use its Generate allow list function. No shell
execution is needed by these scripts.

## Check definitions

| Setting | Event | Metric |
| --- | --- | --- |
| Suggested name | `weather.check-wind` | `weather.metrics-wind` |
| Check type | Event | Metrics |
| Plugin dependency | `acc-weather` | `acc-weather` |
| Command prefix | `check_weather_wind.rb` | `metrics_weather_wind.rb` |
| Execution mode | execv | execv |
| Initial interval | 600 seconds | 600 seconds, staggered |
| Suggested check timeout | 60 seconds | 60 seconds |

The default path makes up to three API requests (two with a pinned station).
Each request has a total time limit of ten seconds by default; set the ACC check
timeout above three times a customized request timeout. There are no immediate
retries or persistent caches. On HTTP 429/5xx the check fails UNKNOWN and the next
scheduled poll tries again. Keep schedules modest, stagger runs, and run once per
facility rather than on every server in that facility. All requests validate TLS.
Configure the ACC service environment's supported HTTP proxy and trusted CA bundle
if outbound access requires them; do not disable certificate verification.

| Parameter | Flag | Required | Default |
| --- | --- | --- | --- |
| Latitude | `--latitude` | Both | none |
| Longitude | `--longitude` | Both | none |
| CI ID | `--ci-id` | Both | none |
| NWS application/contact identity | `--user-agent` | Both | none |
| Warning wind speed | `--warning` | Event only | none |
| Critical wind speed | `--critical` | Event only | none |
| Units | `--units` | No | `mph` |
| Station | `--station` | No | nearest returned station |
| Maximum observation age | `--max-age-minutes` | No | `90` |
| Maximum station distance | `--max-distance-km` | No | `50` |
| Request timeout | `--timeout` | No | `10` |

Choose thresholds for each facility. The metric check deliberately rejects
warning/critical arguments so weather thresholds cannot accidentally be applied
to collection. Event exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN. Metric
exit codes: 0 emitted one observation, 3 emitted no measurement and wrote a
diagnostic to stderr. Confirm how your ACC release surfaces failed metric checks.

## Data center CI association

Resolve the physical data center CI's location reference in the instance and map
the location's latitude/longitude into check parameters. Use the data center
sys_id as `--ci-id`. Missing or invalid coordinates should produce a configuration
failure, not fall back silently to the executing host's location.

The scripts execute on an ACC host with outbound HTTPS access. Configure the
appropriate ACC proxy target and result association so events and metrics bind
to the data center CI instead of the collector host. The `ci=` text and CI ID
metric segment are identification aids, not an automatic CMDB reassignment.
Validate this mapping in your instance before enabling production policies.

The metric is Graphite plaintext, matching the existing AIX reference plugin:
`weather.<ci-id>.wind_speed_<units> <number> <epoch>`. Configure metric mapping and
display units accordingly. Do not place it in an Event check. The observation
timestamp is used intentionally; repeated polling must not make old data appear
new. Confirm your metric ingestion configuration accepts observation timestamps.

## Station behavior

Auto selection uses great-circle distance among stations returned by NWS for
the point. Equal distances are resolved by station ID. The nearest station's
missing/stale wind fails UNKNOWN, without silently switching stations. Review
the station and distance in event output, then pin a suitable station if needed.
A pinned station still has its metadata and distance checked each run.

NWS observations may lag and not all stations report all fields. The reported
wind is representative of the station, not an on-site data center sensor.
The freshness limit is configurable; the supplied 90 minutes accommodates hourly
reports and processing delay but may be too permissive for some operations.

## Acceptance on your ACC deployment

The repository tests do not replace endpoint integration validation. On one
Windows and one Linux test agent, verify bundled Ruby execution, plugin delivery,
certificate trust, allow-list matching, outbound TLS/proxy access, result routing,
and metric ingestion. Exercise OK/WARNING/CRITICAL using temporary test thresholds
and UNKNOWN using a deliberately short freshness limit. Verify that no fake zero
metric is emitted and that the correct data center CI receives both results.

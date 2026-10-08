# Documentation screenshots

These screenshots were supplied by the project owner on 2026-10-07 and are used
as reference images in `../servicenow-configuration.md`. They are copied without
editing. Captions distinguish shown settings from recommended corrections.

| File | Content |
| --- | --- |
| `plugin-settings.png` | ACC plugin properties |
| `data-center-station-configuration.png` | Data Center CI with a single-line station ID in Description |
| `metric-check-definition.png` | Temperature metric definition and station token |
| `event-check-definition.png` | Temperature event definition and generated command |
| `event-parameter-definitions.png` | Four event parameter definitions |
| `policy-monitored-cis.png` | Data Center CI type on the weather policy |
| `policy-check-selection.png` | Example metric and two event instances |
| `low-temperature-check-instance.png` | Example below-temperature instance parameters |

The proxy-agent screenshot is intentionally excluded because it identifies a
specific agent. The guide documents its settings in a table with the instruction
to select an agent from the reader's own environment.

The critical parameter is shown as non-mandatory in the parameter screenshots.
The guide explicitly corrects this to mandatory because the script requires it.
The screenshot default thresholds are examples and are not universal settings.
The updated data center screenshot shows `KSJC` (San Jose International Airport)
as the only line in Description for the Santa Clara, California demo. It replaces
the earlier station-field screenshot and matches the guide's instructions.

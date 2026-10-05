"""Validate the built unsigned payload without extracting untrusted paths."""
import json
import tarfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
metadata = json.loads((root / "plugins/acc-weather/plugin.json").read_text())
with tarfile.open(root / "dist/acc-weather.tar.gz", "r:gz") as archive:
    expected = {f"{folder}/{Path(entry).name}": root / entry
                for folder, entries in metadata["dirs"].items() for entry in entries}
    actual = {m.name for m in archive.getmembers() if m.isfile()}
    assert actual == set(expected), (actual, expected)
    for name, source in expected.items():
        assert archive.extractfile(name).read() == source.read_bytes(), name
        if name.startswith("bin/"):
            assert archive.getmember(name).mode == 0o755, name
    allowlist = json.load(archive.extractfile("allow_list/check-allow-list.json"))
    assert {v["exec"] for v in allowlist} == {"check_weather_wind.rb", "metrics_weather_wind.rb"}
    assert not any(v["allow_shell"] for v in allowlist)
print("Package contents, executable modes, source bytes and allow-list validated.")

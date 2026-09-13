#!/usr/bin/env python3
"""Inject client lists into rendered Xray config.json (used by lib/xray.sh).

Usage: xray_render.py <tag> <clients_json_array> <config_path>

For non-trojan inbounds: clients is a JSON array of uuid strings -> adds
{"id": uuid, "email": "uuid@tag"} so per-user stats work.
For trojan inbounds: clients is an array of {"password": ...} objects.
"""
import json
import sys


def inject(tag: str, clients_json: str, config_path: str) -> None:
    with open(config_path) as f:
        cfg = json.load(f)
    raw = json.loads(clients_json)
    for inbound in cfg.get("inbounds", []):
        if inbound.get("tag") != tag:
            continue
        settings = inbound.setdefault("settings", {})
        if inbound.get("protocol") == "trojan":
            settings["clients"] = [
                {**c, "email": "{0}@{1}".format(c["password"], tag)} for c in raw
            ]
        else:
            settings["clients"] = [
                {"id": c, "email": "{0}@{1}".format(c, tag)} for c in raw
            ]
    with open(config_path, "w") as f:
        json.dump(cfg, f, indent=4)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 1
    tag, clients_json, config_path = sys.argv[1:4]
    inject(tag, clients_json, config_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

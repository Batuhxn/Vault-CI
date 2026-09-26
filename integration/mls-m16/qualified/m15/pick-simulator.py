#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Choose a preinstalled compatible iPhone runtime; never download one."""
import json
import sys


def version(value):
    return tuple(int(part) for part in value.split(".")[:2])


sdk = version(sys.argv[1])
with open(sys.argv[2]) as source:
    runtimes = json.load(source)["runtimes"]
with open(sys.argv[3]) as source:
    devices = json.load(source)["devices"]
runtimes = [runtime for runtime in runtimes
            if runtime.get("isAvailable")
            and "SimRuntime.iOS-" in runtime.get("identifier", "")
            and (16, 0) <= version(runtime["version"]) <= sdk]
if not runtimes:
    sys.exit("no preinstalled compatible iOS Simulator runtime")
runtimes.sort(key=lambda runtime: version(runtime["version"]), reverse=True)
runtime = runtimes[0]
available = sorted((device for device in devices.get(runtime["identifier"], [])
                    if device.get("isAvailable") and device["name"].startswith("iPhone")),
                   key=lambda device: device["name"])
types = sorted((device for device in runtime.get("supportedDeviceTypes", [])
                if device.get("productFamily") == "iPhone"), key=lambda device: device["name"])
if not available and not types:
    sys.exit("compatible runtime has no iPhone device or device type")
print(runtime["identifier"], runtime["version"],
      available[0]["udid"] if available else "-",
      types[0]["identifier"] if types else "-")

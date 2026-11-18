#!/usr/bin/env python3
"""Shared, observational performance log format; never sets XCTest budgets."""
import collections
import json
import math
import os
import platform
import subprocess
import sys


PREFIX = "SICK-PERF "


def distribution(samples):
    values = sorted(samples)
    if not values or any(not math.isfinite(v) or v < 0 for v in values):
        raise ValueError("expected nonempty finite, nonnegative samples")
    def percentile(fraction):
        return values[math.ceil(len(values) * fraction) - 1]
    return dict(n=len(values), min=values[0], p50=percentile(.5) if len(values) >= 5 else None,
                p95=percentile(.95) if len(values) >= 5 else None, max=values[-1])


def environment(build):
    try:
        hardware = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).strip()
    except (OSError, subprocess.SubprocessError):
        hardware = "unbekannt"
    try:
        load = list(os.getloadavg())
    except OSError:
        load = None
    return dict(commit=os.environ.get("SICK_PERF_COMMIT", "unbekannt"), build=build,
                hardware=hardware, macOS=platform.mac_ver()[0] or "unbekannt",
                cores=os.cpu_count(), load_1_5_15=load,
                run=os.environ.get("SICK_PERF_RUN", "einzeln"))


def report():
    record = json.load(sys.stdin)
    record.update(distribution(record["samples"]))
    record["environment"] = environment(record.pop("build"))
    if record["scenario"].startswith("production/"):
        print("BUDGET production deterministisch: erwartete Fake-Sends/Mailbox-Sequenzen, "
              "Note-Off-Status und Stichprobenzahl bleiben harte Assertions; "
              "lastabhaengig: Latenzverteilung mit unveraenderten p99/max-Grenzen")
    print(PREFIX + json.dumps(record, sort_keys=True, separators=(",", ":")), flush=True)


def summarize(directory, repetitions):
    if repetitions < 5:
        raise ValueError("at least five repetitions required")
    groups = collections.defaultdict(list)
    failed = []
    metadata = None
    for run in range(1, repetitions + 1):
        path = os.path.join(directory, f"run-{run}.log")
        with open(path) as stream:
            records = [json.loads(line[len(PREFIX):]) for line in stream if line.startswith(PREFIX)]
        expected = {f"selection/{preset}/{kind}" for preset in ("Harmony 29 Picardy Switch", "Harmony 30 Mode Wheel", "Keller 03 Zwei Haende") for kind in ("layer", "cell")}
        expected |= {"view/90", "view/361", "production/profile-to-send", "production/panic-to-off"}
        actual = collections.Counter(record["scenario"] for record in records)
        if set(actual) != expected or any(count != 1 for count in actual.values()):
            raise ValueError(f"run {run}: missing/duplicate/unexpected reports: {actual}")
        for record in records:
            identity = {key: record["environment"][key] for key in ("commit", "build", "hardware", "macOS", "cores")}
            if metadata is not None and identity != metadata:
                raise ValueError("incompatible measurement environments")
            metadata = identity
            groups[record["scenario"]].append(record)
        with open(os.path.join(directory, f"run-{run}.status")) as stream:
            if stream.read().strip() != "0":
                failed.append(run)
    lines = ["| Szenario | Läufe | n (Einzelwerte) | Einheit | min | p50 | p95 | max | Umgebung je Lauf |",
             "| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | --- |"]
    for scenario, records in sorted(groups.items()):
        if len({record["unit"] for record in records}) != 1:
            raise ValueError("incompatible units")
        stats = distribution([sample for record in records for sample in record["samples"]])
        envs = [record["environment"] for record in records]
        load = "; ".join(f"{env['run']}:{env['load_1_5_15']}" for env in envs)
        lines.append(f"| {scenario} | {len(records)} | {stats['n']} | {records[0]['unit']} | " +
                     " | ".join(f"{stats[key]:.6f}" for key in ("min", "p50", "p95", "max")) + f" | {load} |")
    text = "\n".join(["# QUALITÄT-D Messung", "", json.dumps(metadata, ensure_ascii=False), "",
                       "Nearest rank; gepoolte Einzelwerte je Szenario, keine Perzentile von Perzentilen. "
                       "Bei fünf CPU-/Auswahlwerten ist p95 das Maximum, keine stabile Tail-Schätzung. "
                       "Lastmittel sind Indikatoren, kein Beleg einer exklusiven/ruhigen Maschine.", "",
                       *lines, "", f"Rote Läufe (unverändert enthalten): {failed}", ""])
    with open(os.path.join(directory, "baseline.md"), "w") as stream:
        stream.write(text)
    print(text)
    return bool(failed)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "summarize":
        sys.exit(summarize(sys.argv[2], int(sys.argv[3])))
    elif len(sys.argv) == 1:
        report()
    else:
        sys.exit("usage: perf-report.py [summarize DIRECTORY REPETITIONS]")

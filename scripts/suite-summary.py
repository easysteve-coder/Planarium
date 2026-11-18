#!/usr/bin/env python3
"""Profiled SwiftPM runner. Standard library only; no inferred green results."""
import argparse
from collections import Counter
from datetime import datetime
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
PROFILES = ROOT / "scripts/suite-profiles.tsv"
# Four processes on the 10-core MacBookPro18,1 leave capacity for AppKit and
# filesystem work. Timing assertions run after every parallel worker exited.
WORKERS = 4
CASE = re.compile(r"Test Case '-\[([^ ]+) ([^]]+)\]' (passed|failed|skipped) \(", re.M)
CRASH = re.compile(r"unexpected signal|Fatal error")
MARKER = "SUITE-SUMMARY "


def read_profiles(path=PROFILES):
    rows = []
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        kind, pattern, triggers, reason = line.split("\t", 3)
        if kind not in ("long", "timing") or not all((pattern, triggers, reason)):
            raise ValueError("Ungültige Profilzeile: " + line)
        rows.append((kind, pattern, triggers.split("|"), reason))
    return rows


def plan(tests, rows, profile, changed):
    timing, omitted = set(), set()
    decisions = []
    for kind, pattern, triggers, reason in rows:
        matched = {test for test in tests if re.search(pattern, test)}
        if not matched:
            raise ValueError("Profilfilter trifft keinen Test: " + pattern)
        touched = any(fnmatch.fnmatchcase(path, glob) for path in changed for glob in triggers)
        if kind == "timing":
            timing.update(matched)
        elif profile == "quick" and not touched:
            omitted.update(matched)
        decisions.append(dict(kind=kind, filter=pattern, included=kind == "timing" or profile == "full" or touched,
                              touched=touched, reason=reason))
    omitted -= timing
    return dict(parallel=sorted(set(tests) - timing - omitted), timing=sorted(timing),
                omitted=sorted(omitted), decisions=decisions)


def serial_cases(body):
    return [(f"{cls}/{name}", result) for cls, name, result in CASE.findall(body)]


def xml_cases(path):
    cases = []
    for case in ET.parse(path).getroot().iter("testcase"):
        result = "failed" if case.find("failure") is not None or case.find("error") is not None else (
            "skipped" if case.find("skipped") is not None else "passed")
        cases.append((f"{case.attrib['classname']}/{case.attrib['name']}", result))
    if not cases:
        raise ValueError("Leeres xUnit-Ergebnis")
    return cases


def summarize(log):
    body = log.read_text(errors="replace")
    counts = Counter(passed=0, failed=0, skipped=0)
    crashed = max(body.count("unexpected signal"), body.count("Fatal error"))
    build_errors = len(re.findall(r"^error: (?!Process .*exited with unexpected signal|Exited with unexpected signal)", body, re.M))
    invalid = []
    records = []
    for line in body.splitlines():
        if line.startswith(MARKER):
            records.append(json.loads(line[len(MARKER):]))
    planned = [line[len("SUITE-PLAN "):] for line in body.splitlines() if line.startswith("SUITE-PLAN ")]
    if planned:
        selection = json.loads((log.parent / planned[0]).read_text())
        expected_stages = {kind: selection[kind] for kind in ("parallel", "timing") if selection[kind]}
        if len(planned) != 1 or Counter(record["kind"] for record in records) != Counter(expected_stages.keys()):
            invalid.append("Geplante Stufen fehlen oder sind doppelt")
        if not any(line.startswith("SUITE-END ") for line in body.splitlines()):
            invalid.append("Suite wurde nicht abgeschlossen")
        for record in records:
            if record["expected"] != expected_stages.get(record["kind"]):
                invalid.append("Stufe widerspricht dem gespeicherten Plan")
    if records:
        crashed = 0
        # Each stage has an independent log and exit status. A later successful
        # stage cannot mask a failed build, missing XML, signal or missing test.
        for record in records:
            stage = log.parent / record["log"]
            stage_body = stage.read_text(errors="replace")
            crashed += max(stage_body.count("unexpected signal"), stage_body.count("Fatal error"))
            if record["kind"] == "parallel":
                try:
                    xml = xml_cases(log.parent / record["xml"])
                    cases = serial_cases(stage_body)
                    if Counter(name for name, _ in xml) != Counter(name for name, _ in cases):
                        invalid.append("Paralleles XCTest-Protokoll unvollständig (verbose nötig)")
                    if Counter(name for name, result in xml if result == "failed") != Counter(name for name, result in cases if result == "failed"):
                        invalid.append("xUnit/XCTest-Fehler widersprechen sich")
                except (OSError, ET.ParseError, ValueError, KeyError) as error:
                    cases = []
                    invalid.append("xUnit: " + str(error))
            else:
                cases = serial_cases(stage_body)
            counts.update(result for _, result in cases)
            if Counter(name for name, _ in cases) != Counter(record["expected"]):
                invalid.append("Testmenge unvollständig/doppelt: " + record["kind"])
            if record["status"]:
                invalid.append(f"{record['kind']}: swift test Status {record['status']}")
            if record["status"] < 0 and not CRASH.search(stage_body):
                crashed += 1
    else:
        # Historical serial logs and Terra's first parallel logs remain readable.
        xml = log.with_suffix(".xunit.xml")
        if xml.exists():
            try:
                parallel = xml_cases(xml)
                before_timing = re.split(r"(?:\\n)?===== timing:", body, maxsplit=1)[0]
                cases = serial_cases(before_timing)
                counts.update(result for _, result in cases)
                if Counter(name for name, _ in parallel) != Counter(name for name, _ in cases):
                    invalid.append("Historisches Parallel-Log ohne vollständige XCTest-Ausgabe; xUnit verliert Skips")
                timing = re.split(r"(?:\\n)?===== timing:", body, maxsplit=1)
                if len(timing) == 2:
                    counts.update(result for _, result in serial_cases(timing[1]))
            except (OSError, ET.ParseError, ValueError, KeyError) as error:
                invalid.append("xUnit: " + str(error))
        else:
            counts.update(result for _, result in serial_cases(body))
            if re.search(r"^\[\d+/\d+\] Testing ", body, re.M):
                invalid.append("Paralleles Log ohne xUnit: keine verlässliche Zählung")
    print(f"bestanden:     {counts['passed']}\nrot:           {counts['failed']}\nuebersprungen: {counts['skipped']}\nabgestuerzt:   {crashed}\nbaufehler:     {build_errors}\nlog:           {log}")
    if not sum(counts.values()):
        invalid.append("KEIN LAUF: nicht ein einziger Testfall")
    for problem in invalid:
        print("UNGÜLTIG: " + problem, file=sys.stderr)
    return int(bool(invalid or counts['failed'] or crashed or build_errors))


def execute(args):
    start = time.monotonic()
    runs = ROOT / ".agent_handoff/runs"
    runs.mkdir(parents=True, exist_ok=True)
    # Exclusive creation prevents same-second runs overwriting each other's log.
    stem = datetime.now().strftime("%Y%m%d-%H%M%S-%f") + f"-{args.profile}-suite"
    log = runs / (stem + ".log")
    log.touch(exist_ok=False)
    swift = ["swift", "test", "--disable-swift-testing"]
    listing = subprocess.run(swift + ["--list-tests"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    log.write_text(listing.stderr)
    if listing.returncode:
        with log.open("a") as output:
            output.write(listing.stdout + "\nerror: Testinventar/Bau gescheitert\n")
        return summarize(log)
    tests = sorted(set(re.findall(r"^\w+\.\w+/\w+$", listing.stdout, re.M)))
    if not tests:
        raise ValueError("SwiftPM lieferte kein Testinventar; Log: " + str(log))
    if args.filter:
        selected = [test for test in tests if re.search(args.filter, test)]
        if not selected:
            raise ValueError("Filter trifft keinen Test: " + args.filter)
        selection = dict(parallel=[], timing=selected, omitted=[], decisions=[])
    else:
        changed = subprocess.check_output(["git", "diff", "--name-only", "HEAD", "-z"]).decode().split("\0")
        selection = plan(tests, read_profiles(), args.profile, changed)
    (runs / (stem + ".plan.json")).write_text(json.dumps(selection, indent=2) + "\n")
    with log.open("a") as output:
        output.write("\nSUITE-PLAN " + stem + ".plan.json\n")
    print(f"{args.profile}: {len(selection['parallel'])} parallel ({WORKERS} Worker), {len(selection['timing'])} seriell, {len(selection['omitted'])} ausgelassen", flush=True)
    for kind in ("parallel", "timing"):
        expected = selection[kind]
        if not expected:
            continue
        # Exact identity filters make stage ownership disjoint, even when a
        # broad class filter overlaps a long-running individual test.
        if kind == "parallel":
            excluded = selection["timing"] + selection["omitted"]
            command = swift + ["--skip-build", "--parallel", "--num-workers", str(WORKERS), "--verbose"]
            if excluded:
                command += ["--skip", "^(?:" + "|".join(map(re.escape, excluded)) + ")$"]
        else:
            command = swift + ["--skip-build", "--filter", args.filter or "^(?:" + "|".join(map(re.escape, expected)) + ")$"]
        stage = runs / (stem + f".{kind}.log")
        xml = runs / (stem + ".xunit.xml")
        if kind == "parallel":
            command += ["--xunit-output", str(xml)]
        # Tests normally use UUID temp dirs. Keep their evidence outside the
        # tracked Owner-image directory, including OwnerRun1010's fallback.
        env = os.environ.copy()
        env["SICK_TEST_ARTIFACT_DIR"] = str(runs / (stem + ".artifacts"))
        env["SICK_TEST_ISOLATE_ARTIFACTS"] = "1"
        Path(env["SICK_TEST_ARTIFACT_DIR"]).mkdir(exist_ok=True)
        stage_start = time.monotonic()
        with stage.open("w") as output:
            status = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, env=env).returncode
        record = dict(kind=kind, status=status, log=stage.name, expected=expected, xml=xml.name)
        with log.open("a") as output:
            output.write("\n" + stage.read_text(errors="replace"))
            output.write("\n" + MARKER + json.dumps(record) + "\n")
        print(f"{kind}: Status {status}, Wandzeit {time.monotonic() - stage_start:.2f} s", flush=True)
    with log.open("a") as output:
        output.write(f"\nSUITE-END Wandzeit: {time.monotonic() - start:.2f} s\n")
    return summarize(log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--quick", dest="profile", action="store_const", const="quick")
    mode.add_argument("--full", dest="profile", action="store_const", const="full")
    parser.set_defaults(profile="full")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--filter")
    source.add_argument("--log", type=Path)
    args = parser.parse_args()
    if args.profile == "quick" and (args.filter or args.log):
        parser.error("--quick kann nicht mit --filter/--log kombiniert werden")
    os.chdir(ROOT)
    try:
        return summarize(args.log) if args.log else execute(args)
    except (OSError, ValueError, ET.ParseError) as error:
        print("Fehler: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Builds and times the benchmarks and checks each program's output against
benchmarks/expected.

By default it times only Willow and prints one line per benchmark, for
comparing Willow with itself before and after a change. `--all` also times
the other languages, which needs cc, go, and node on PATH. `--readme` times
every language and replaces the results table in README.md.

Run it from anywhere after `make`.
"""

import argparse
import platform
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HERE = ROOT / "benchmarks"
BUILD = HERE / "build"
LUAJIT = ROOT / "vendor" / "luajit" / "src" / "luajit"
README = ROOT / "README.md"
START = "<!-- benchmarks:start -->"
END = "<!-- benchmarks:end -->"
RUNS = 3

BENCHMARKS = [
    ("n_body", "n-body", 5_000_000),
    ("spectral_norm", "spectral-norm", 2_000),
    ("fannkuch_redux", "fannkuch-redux", 10),
    ("binary_trees", "binary-trees", 18),
]

LANGUAGES = ["C", "Go", "Node", "LuaJIT", "Willow", "Python"]


def build(name, languages):
    """Builds `name` in each of `languages` and returns the command that runs
    it, without the size argument, keyed by language."""
    c = BUILD / f"{name}_c"
    go = BUILD / f"{name}_go"
    lua = BUILD / f"{name}.lua"
    if "C" in languages:
        subprocess.run(["cc", "-O2", "-o", c, HERE / "c" / f"{name}.c", "-lm"], check=True)
    if "Go" in languages:
        subprocess.run(["go", "build", "-o", go, HERE / "go" / f"{name}.go"], check=True)
    subprocess.run([ROOT / "willow", "compile", HERE / "willow" / f"{name}.wlo", "-o", lua], check=True)
    return {
        "C": [c],
        "Go": [go],
        "Node": ["node", HERE / "node" / f"{name}.js"],
        "LuaJIT": [LUAJIT, HERE / "lua" / f"{name}.lua"],
        "Willow": [LUAJIT, lua],
        "Python": [sys.executable, HERE / "python" / f"{name}.py"],
    }


def best_time(command):
    """Returns the fastest of RUNS wall-clock times and the output."""
    best = None
    for _ in range(RUNS):
        start = time.perf_counter()
        output = subprocess.run(command, check=True, capture_output=True, text=True).stdout
        elapsed = time.perf_counter() - start
        best = elapsed if best is None else min(best, elapsed)
    return best, output


def machine():
    if platform.system() == "Darwin":
        cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout
    else:
        lines = Path("/proc/cpuinfo").read_text().splitlines()
        cpu = next((line.split(":", 1)[1] for line in lines if line.startswith("model name")), platform.machine())
    return f"{cpu.strip()}, {platform.system()}"


def table(results):
    lines = [
        f"Seconds of wall-clock time, best of {RUNS} runs, on {machine()}.",
        "",
        "| Benchmark (size) | " + " | ".join(LANGUAGES) + " |",
        "|---|" + "---:|" * len(LANGUAGES),
    ]
    for _, title, size in BENCHMARKS:
        times = " | ".join(f"{results[title][language]:.2f}" for language in LANGUAGES)
        lines.append(f"| {title} ({size:,}) | {times} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--all", action="store_true", help="also time the other languages")
    parser.add_argument("--readme", action="store_true", help="time every language and update README.md")
    parser.add_argument("names", nargs="*", metavar="benchmark", help="benchmarks to run (default: all)")
    args = parser.parse_args()

    titles = [title for _, title, _ in BENCHMARKS]
    unknown = [name for name in args.names if name not in titles]
    if unknown:
        parser.error(f"unknown benchmark {', '.join(unknown)}; choose from {', '.join(titles)}")
    if args.readme and args.names:
        parser.error("--readme runs every benchmark")
    languages = LANGUAGES if args.all or args.readme else ["Willow"]

    BUILD.mkdir(exist_ok=True)
    results = {}
    failed = False
    for name, title, size in BENCHMARKS:
        if args.names and title not in args.names:
            continue
        commands = build(name, languages)
        expected = (HERE / "expected" / f"{name}.txt").read_text()
        results[title] = {}
        for language in languages:
            elapsed, output = best_time(commands[language] + [str(size)])
            results[title][language] = elapsed
            prefix = title if languages == ["Willow"] else f"{title} {language}"
            print(f"{prefix} {elapsed:.3f}s", flush=True)
            if output != expected:
                print(f"{title}: {language} output differs from benchmarks/expected/{name}.txt", file=sys.stderr)
                failed = True
    if failed:
        sys.exit(1)

    if args.readme:
        text = README.read_text()
        before, rest = text.split(START, 1)
        _, after = rest.split(END, 1)
        README.write_text(f"{before}{START}\n{table(results)}\n{END}{after}")
        print(f"updated {README.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Builds and times every benchmark in every language, checks that each
language prints the same output, and replaces the results table in README.md.

Run it from anywhere after `make`. It needs cc, go, node, and python3 on PATH.
"""

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


def build(name):
    """Builds `name` in each language and returns the command that runs it,
    without the size argument, keyed by language."""
    c = BUILD / f"{name}_c"
    go = BUILD / f"{name}_go"
    lua = BUILD / f"{name}.lua"
    subprocess.run(["cc", "-O2", "-o", c, HERE / "c" / f"{name}.c", "-lm"], check=True)
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
    BUILD.mkdir(exist_ok=True)
    results = {}
    failed = False
    for name, title, size in BENCHMARKS:
        commands = build(name)
        results[title] = {}
        outputs = {}
        for language in LANGUAGES:
            elapsed, outputs[language] = best_time(commands[language] + [str(size)])
            results[title][language] = elapsed
            print(f"{title} {language}: {elapsed:.2f}s", flush=True)
        for language in LANGUAGES:
            if outputs[language] != outputs["C"]:
                print(f"{title}: {language} output differs from C", file=sys.stderr)
                failed = True
    if failed:
        sys.exit(1)

    text = README.read_text()
    before, rest = text.split(START, 1)
    _, after = rest.split(END, 1)
    README.write_text(f"{before}{START}\n{table(results)}\n{END}{after}")
    print(f"updated {README.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

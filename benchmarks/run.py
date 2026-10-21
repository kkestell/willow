#!/usr/bin/env python3
"""Builds and times the benchmarks and checks the SHA-256 digest of each
program's output against benchmarks/expected.

By default it times only Willow and prints one line per benchmark, for
comparing Willow with itself before and after a change. `--all` also times
the other languages, which needs cc on PATH. `--readme` times every language
and replaces the results table in README.md.

Run it from anywhere after `make`.
"""

import argparse
import hashlib
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
    ("fasta", "fasta", 2_500_000),
    ("mandelbrot", "mandelbrot", 2_500),
    ("k_nucleotide", "k-nucleotide", 2_500_000),
    ("reverse_complement", "reverse-complement", 5_000_000),
    ("recursive", "recursive", 9),
    ("nsieve", "nsieve", 11),
    ("matrix", "matrix", 10_000),
    ("methcall", "methcall", 50_000_000),
    ("except", "except", 1_000_000),
    ("heapsort", "heapsort", 2_000_000),
    ("hash2", "hash2", 5_000),
    ("sumcol", "sumcol", 10_000_000),
    ("raytracer", "raytracer", 200),
]

LANGUAGES = ["C", "LuaJIT", "Python", "Willow"]


def fasta_input(size, path):
    """Writes the output of fasta for `size`."""
    with path.open("wb") as out:
        subprocess.run([ROOT / "willow", "run", HERE / "willow" / "fasta.wlo", str(size)], stdout=out, check=True)


def sumcol_input(size, path):
    """Writes `size` lines of integers from -1000 through 1000, chosen with
    fasta's random number generator."""
    lines, last = [], 42
    for _ in range(size):
        last = (last * 3877 + 29573) % 139968
        lines.append(f"{last % 2001 - 1000}\n")
    path.write_text("".join(lines))


# Benchmarks that read standard input instead of taking the size as an
# argument, with the function that writes their input for a size.
INPUTS = {"reverse_complement": fasta_input, "sumcol": sumcol_input}


def build(name, languages):
    """Builds `name` in each of `languages` and returns the command that runs
    it, without the size argument, keyed by language."""
    c = BUILD / f"{name}_c"
    lua = BUILD / f"{name}.lua"
    if "C" in languages:
        subprocess.run(["cc", "-O2", "-o", c, HERE / "c" / f"{name}.c", "-lm"], check=True)
    subprocess.run([ROOT / "willow", "compile", HERE / "willow" / f"{name}.wlo", "-o", lua], check=True)
    return {
        "C": [c],
        "LuaJIT": [LUAJIT, HERE / "lua" / f"{name}.lua"],
        "Willow": [LUAJIT, lua],
        "Python": [sys.executable, HERE / "python" / f"{name}.py"],
    }


def best_time(command, stdin):
    """Returns the fastest of RUNS wall-clock times and the output's digest.
    `stdin` is the path of the program's input, or None."""
    best = None
    for _ in range(RUNS):
        with open(stdin or "/dev/null", "rb") as source:
            start = time.perf_counter()
            output = subprocess.run(command, stdin=source, check=True, capture_output=True).stdout
            elapsed = time.perf_counter() - start
        best = elapsed if best is None else min(best, elapsed)
    return best, hashlib.sha256(output).hexdigest()


def machine():
    if platform.system() == "Darwin":
        cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout
    else:
        lines = Path("/proc/cpuinfo").read_text().splitlines()
        cpu = next((line.split(":", 1)[1] for line in lines if line.startswith("model name")), platform.machine())
    return f"{cpu.strip()}, {platform.system()}"


def table(results):
    lines = [
        f"Seconds of wall-clock time, best of {RUNS} runs, on {machine()}. In",
        "parentheses is how many times faster Willow is than Python.",
        "",
        "| Benchmark (size) | C | LuaJIT | Python | Willow (vs Python) |",
        "|---|---:|---:|---:|---:|",
    ]
    for _, title, size in BENCHMARKS:
        times = results[title]
        speedup = times["Python"] / times["Willow"]
        lines.append(
            f"| {title} ({size:,}) | {times['C']:.2f} | {times['LuaJIT']:.2f} | {times['Python']:.2f}"
            f" | {times['Willow']:.2f} ({speedup:.1f}x) |"
        )
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
        stdin = None
        arguments = [str(size)]
        if name in INPUTS:
            stdin = BUILD / f"{name}_input"
            INPUTS[name](size, stdin)
            arguments = []
        expected = (HERE / "expected" / f"{name}.sha256").read_text().strip()
        results[title] = {}
        for language in languages:
            elapsed, digest = best_time(commands[language] + arguments, stdin)
            results[title][language] = elapsed
            prefix = title if languages == ["Willow"] else f"{title} {language}"
            print(f"{prefix} {elapsed:.3f}s", flush=True)
            if digest != expected:
                print(f"{title}: {language} output digest {digest} differs from benchmarks/expected/{name}.sha256", file=sys.stderr)
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

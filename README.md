# Willow

Willow is a small, statically typed language with Python-like syntax. Its
self-hosting compiler turns `.wlo` files into native executables through QBE.

[Specification](docs/spec.md) · [Language tour](examples/tour.wlo) · [Examples](examples/)

## Setup

Requires macOS or Linux, a C compiler, QBE 1.3, and libgc (bdw-gc).

```sh
make
make test
make install  # install to ~/.local/bin; add it to your PATH
```

## Usage

```sh
willow run hello.wlo                  # run a program
willow check hello.wlo                # type-check
willow build hello.wlo -o hello       # build an executable
willow test tests                     # run tests
willow init                           # create a project
```

Projects use `willow.json` for configuration. Inside a project, `willow run`,
`willow build`, and `willow test` use that configuration without a filename.
See [examples/projects](examples/projects) for an example.

## Benchmarks

Local single-threaded comparisons with C and Python. Run
`python3 benchmarks/run.py` to time Willow, or `--all` to time every language.
`--readme` writes the new times into the table, so `--readme` alone updates
the Willow column and `--readme --all` every column.

<!-- benchmarks:start -->
Seconds of wall-clock time, best of 3 runs, on Apple M4, Darwin.

| Benchmark (size) | C | Willow | Python |
|---|---:|---:|---:|
| n-body (5,000,000) | 0.16 | 0.68 | 12.15 |
| spectral-norm (2,000) | 0.12 | 0.59 | 12.44 |
| fannkuch-redux (10) | 0.14 | 0.33 | 2.70 |
| binary-trees (18) | 0.85 | 0.84 | 11.88 |
| fasta (2,500,000) | 0.23 | 0.73 | 2.58 |
| mandelbrot (2,500) | 0.19 | 1.31 | 8.44 |
| k-nucleotide (2,500,000) | 0.20 | 1.68 | 1.59 |
| reverse-complement (5,000,000) | 0.11 | 1.56 | 0.27 |
| recursive (9) | 0.18 | 0.25 | 2.77 |
| nsieve (11) | 0.09 | 0.53 | 2.86 |
| matrix (10,000) | 0.06 | 0.71 | 6.17 |
| methcall (50,000,000) | 0.19 | 1.03 | 4.26 |
| except (1,000,000) | 0.57 | 0.04 | 0.31 |
| heapsort (2,000,000) | 0.21 | 0.39 | 3.97 |
| hash2 (5,000) | 0.56 | 1.77 | 4.22 |
| sumcol (10,000,000) | 0.31 | 0.47 | 0.63 |
| raytracer (200) | 0.05 | 0.62 | 7.85 |
<!-- benchmarks:end -->

## Editor support

Link the [VS Code extension](editors/vscode) into your extensions directory,
then restart VS Code:

```sh
ln -s "$PWD/editors/vscode" ~/.vscode/extensions/willow
```

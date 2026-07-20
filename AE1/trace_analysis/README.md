# AE1 trace analysis — figure pipeline

This directory turns the bundled per-page CSVs into the paper's Figure 2, 5,
and 7 panels. **Start from [`../README.md`](../README.md)** for requirements and
figure descriptions; this file documents the pipeline mechanics for anyone
working inside the directory.

## Pipeline

```text
traces/*.csv.gz  ──►  figureN/figure_*.py  ──►  generated_figNx.png
```

Each figure lives in its own self-contained directory holding a plot script, a
one-command runner, and two sets of panels — no byproduct files:

| File | Meaning |
|------|---------|
| `expected_figNx.png` | the panel as published, shipped with the artifact |
| `generated_figNx.png` | the panel written by `run_figN.sh` |

Each runner renders the panels and renames the plot script's verbose output
names to the deterministic `generated_*` names. Only `generated_*` is
overwritten; the shipped `expected_*` panels are left untouched.

```bash
bash figure2/run_fig2.sh
bash figure5/run_fig5.sh
bash figure7/run_fig7.sh
```

The plot scripts read the bundled `.csv.gz` **directly** — pandas decompresses
on the fly, so there is no unpack step, no temp directory, and nothing left on
disk afterward.

Rendering is deterministic given the bundled CSVs, but output is not
byte-stable across environments: the plot scripts request the Arial font, which
is frequently absent on Linux, and Matplotlib then falls back to another font.
Font and Matplotlib version differences change label rendering and tick spacing
while leaving the plotted data unchanged.

## Regenerating the inputs (`regenerate.sh`)

`regenerate.sh` rebuilds `traces/*.csv.gz` from the raw `.bin` memory traces
using the vendored parser in `parser/`:

```bash
bash regenerate.sh [--traces-root DIR] [--skip-fig7]
```

| Tool (under `parser/`) | Produces |
|---|---|
| `src/cli.py pages` | `{workload}_all_1ms_0ms-1000ms.csv` (fig7) |
| `pdf_parser/gen_nonacc.py` | `{workload}_nonacc_all_1ms_10ms-11ms.csv` (fig2/5 base) |
| `pdf_parser/gen_nonacc_algo.py` | `{workload}_nonacc_hotlist_{lfu_ao,cms_ee}_th{32,64,96}_…csv` (fig2/5 hot sets) |

`parser/` mirrors the upstream parser repository's layout (`src/` beside
`pdf_parser/`) so the vendored scripts run unmodified — they resolve `src` via
`sys.path.insert(0, Path(__file__).parent.parent)`. `PARSER_ROOT` overrides the
parser location for development only.

The raw `.bin` traces are not redistributed; see [`../README.md`](../README.md)
for the expected filenames and for how they were captured.

## Which input feeds which figure

The two input groups are **not** interchangeable:

| Input | Granularity | Used by |
|---|---|---|
| `_all_1ms_0ms-1000ms.csv` | one row per page, cumulative over 0–1000 ms | fig7 only |
| `_nonacc_all_1ms_10ms-11ms.csv` | one row per (page, epoch), single 1 ms epoch | fig2 / fig5 base |
| `_nonacc_hotlist_*` | (page, epoch) pairs selected as hot | fig2 / fig5 hot sets |

Accumulating over 1000 ms discards the per-epoch structure fig2/fig5 plot, and
the cumulative CSV lacks both `epoch_idx` (the hotlist merge key) and
`active_span_us` (the burstiness denominator). The hotlists are selector
outputs — CMS is an approximate sketch — so they cannot be recomputed from
exact per-page counts.

## Layout

```
trace_analysis/
├── README.md
├── regenerate.sh       rebuild traces/*.csv.gz from the raw .bin traces
├── parser/             vendored trace parser (src/, pdf_parser/)
├── traces/             bundled input CSVs (.csv.gz), grouped by workload
├── figure2/            figure_page_dist.py   run_fig2.sh   {expected,generated}_fig2{a,b,c}.png
├── figure5/            figure_th_sweep.py    run_fig5.sh   {expected,generated}_fig5{a,b}.png
└── figure7/            figure_access_dist.py run_fig7.sh   {expected,generated}_fig7{a,b,c}.png
```

# AE1 – Trace-Based Hotness Analysis (Figures 2, 5, 7)

AE1 generates the paper's trace-analysis figures from bundled per-page CSVs.
Unlike AE2/AE3/AE4, it needs no SPR1 host, FPGA image, or custom kernel — only
`python3`. Each figure has a one-command runner that renders its panels. This
front section is the complete generation path. Trace collection, input
regeneration, and per-figure details are preserved in the
[Appendix](#appendix-detailed-reference).

## Artifact at a glance

| Item | Generation path |
|---|---|
| Target | Figures 2, 5, and 7 |
| Hardware | None — runs on any Linux/macOS machine |
| Inputs | Bundled per-page CSVs in [`trace_analysis/traces/`](trace_analysis/traces/) (`.csv.gz`, ~19 MB) |
| Long-running step | None — each runner renders in seconds |
| Main output | `generated_figNx.png` beside each runner |

Trace **collection** is out of scope here. It requires the CXL-Tracer FPGA
platform and two servers, so the traces were captured in advance and the
derived CSVs are bundled. The collection framework is included as a submodule
for provenance — see [Trace collection](#trace-collection-cxl-tracer).

## Quick start

No setup, no privilege, and no external benchmark installation are required.

### 1. Check the requirements

- `python3` with `matplotlib`, `numpy`, `pandas`

### 2. Generate every figure

```bash
cd MICRO-2026-ARC/AE1
bash trace_analysis/figure2/run_fig2.sh
bash trace_analysis/figure5/run_fig5.sh
bash trace_analysis/figure7/run_fig7.sh
```

The paths are self-resolving, so the runners also work from the repository
root or from anywhere else. The plot scripts read the bundled `.csv.gz`
directly — pandas decompresses on the fly, so there is no unpack step, no temp
directory, and nothing left on disk afterward.

## Output

Each runner writes its panels beside the plot script:

```text
trace_analysis/figure2/generated_fig2{a,b,c}.png
trace_analysis/figure5/generated_fig5{a,b}.png
trace_analysis/figure7/generated_fig7{a,b,c}.png
```

| File | Meaning |
|---|---|
| `expected_figNx.png` | the panel as published, shipped with the artifact |
| `generated_figNx.png` | the panel written by `run_figN.sh` |

The runners overwrite only `generated_*`; the shipped `expected_*` panels are
left untouched.

Rendering is deterministic given the bundled CSVs, but the panels are not
byte-identical across environments: the plot scripts request Arial, which is
often absent on Linux, and Matplotlib then falls back to another font. Font and
Matplotlib version differences change label rendering and tick spacing while
leaving the plotted data unchanged.

# Appendix: Detailed reference

## What is included

| Component | Function | When it is used |
|---|---|---|
| `trace_analysis/figure{2,5,7}` | Plot script, runner, and reference panels per figure | Figure generation |
| `trace_analysis/traces` | Bundled per-page input CSVs (`.csv.gz`), grouped by workload | Figure generation |
| `trace_analysis/regenerate.sh` | Rebuilds `traces/*.csv.gz` from the raw `.bin` traces | Optional provenance |
| `trace_analysis/parser` | Vendored trace parser (`src/`, `pdf_parser/`) used by `regenerate.sh` | Optional provenance |
| `cxl-tracer` | CXL-Tracer submodule — the FPGA framework that captured the raw traces | Provenance only |

## Trace collection (`cxl-tracer/`)

The raw memory traces were captured with
[CXL-Tracer](https://github.com/ece-fast-lab/cxl-tracer), included here as a
submodule pinned to the `MICRO_2026_ARC_artifact` branch:

```bash
git submodule update --init --recursive
```

Collection is **not part of this figure-generation path**. It needs an Intel
Agilex 7 FPGA acting as a CXL Type-3 device plus two machines — a target server
running the workload over the CXL link and a separate collection server draining
the trace buffer over PCIe. Reproducing that setup is impractical here, so the
traces were collected in advance and only the derived CSVs are bundled.

For the setup and the artifact benchmark runner, see
[`cxl-tracer/README.md`](cxl-tracer/README.md) and
[`cxl-tracer/sw/TRACE_ARTIFACT.md`](cxl-tracer/sw/TRACE_ARTIFACT.md). The traces
behind the bundled CSVs come from GAPBS (`bc`, `pr` on Twitter) and SPEC CPU2017
(`502.gcc_r`, 8 copies), captured with the workload's memory bound to one CXL
NUMA node.

## Optional: regenerate the inputs from raw traces

The bundled `traces/*.csv.gz` are the fast path. To reproduce them from the raw
`.bin` memory traces (raw trace → CSV → figure):

```bash
bash trace_analysis/regenerate.sh [--traces-root DIR] [--skip-fig7]
```

It re-derives every bundled CSV with the same tools that produced them, gzips
them back into `traces/`, after which the figure runners above are re-run. The
parser is vendored under `trace_analysis/parser/`, so no external checkout is
needed; `PARSER_ROOT` overrides it for development only.

| Option | Effect |
|---|---|
| `--traces-root DIR` | Root holding `gapbs/` and `spec/` `.bin` files (default `/fast-lab-share/cxl_traces/traces`) |
| `--skip-fig7` | Only regenerate the cheap fig2/5 inputs, skipping the slow 1000 ms pass |

The scanners stop at the analysis window, so this reads only the first 11 ms
(fig2/5, seconds) or 1000 ms (fig7, minutes per trace) — not the full multi-GB
traces. Raw traces are expected as `gapbs/gapbs_pr_twitter_t8_n10000000.bin`,
`gapbs/gapbs_bc_twitter_t8_n10000000.bin`, and `spec/spec_502_gcc_r_c8.bin`.
They are not redistributed with this artifact.

The tools used are `src/cli.py pages` for the fig7 all-CSVs and
`pdf_parser/gen_nonacc.py` / `gen_nonacc_algo.py` for the fig2/5 nonacc and
hotlist CSVs.

## Figures

### Figure 2 — per-page hotness distribution  (`trace_analysis/figure2/`)
2D density of pages over **access count** (x) vs **burstiness** = access rate in
accesses/s (y), for the `gapbs_pr_twitter` workload, 1 ms epochs, window 10–11 ms.

| Panel | Content |
|-------|---------|
| `fig2a` | all pages |
| `fig2b` | pages selected as hot by **LFU (always-on)**, threshold 32 |
| `fig2c` | pages selected as hot by **CMS (epoch-end)**, threshold 32 |

- Script: `figure_page_dist.py`  ·  Runner: `run_fig2.sh`
- fig2b/fig2c share one color scale so the two selectors are directly comparable.

### Figure 5 — threshold-sweep selection  (`trace_analysis/figure5/`)
Same axes as Figure 2, but each panel sweeps the hotness **threshold** (32 / 64 /
96) as sub-plots, showing how each selector's hot set responds to the threshold.
Same workload / epoch / window as Figure 2.

| Panel | Content |
|-------|---------|
| `fig5a` | **LFU (always-on)**, threshold sweep 32 / 64 / 96 |
| `fig5b` | **CMS (epoch-end)**, threshold sweep 32 / 64 / 96 |

- Script: `figure_th_sweep.py`  ·  Runner: `run_fig5.sh`
- Both panels share one color scale (unified across algorithms and thresholds).

### Figure 7 — access-count vs elapsed-time distribution  (`trace_analysis/figure7/`)
2D density of pages over **access count** (x, log2) vs **elapsed time** in ms
(y, log), for 1 ms epochs over the 0–1000 ms window. Illustrates how per-page
access counts evolve with time across workloads.

| Panel | Workload |
|-------|----------|
| `fig7a` | `spec_502_gcc_r_c8` |
| `fig7b` | `gapbs_bc_twitter` |
| `fig7c` | `gapbs_pr_twitter` |

- Script: `figure_access_dist.py`  ·  Runner: `run_fig7.sh`
- The x-axis range and colorbar are shared across **all** workloads so the three
  panels are comparable. Those shared values are **frozen** as constants inside
  `figure_access_dist.py` (computed once over the full workload set), so only the
  three bundled workloads are needed while the panels stay identical to the paper.

> **Note on CMS.** The CMS panels (fig2c / fig5b) use the **epoch-end**
> (`cms_ee`) hotlist. The always-on variant is not equivalent: epoch-end
> re-scans the whole sketch at flush, so hash-collision-inflated entries are also
> flagged as hot (uncapped on `gapbs_pr` th=32: 19,982 pages epoch-end vs 9,844
> always-on, the always-on set being a strict subset). `gen_nonacc_algo.py` can
> emit both, but only `cms_ee` is bundled and used here.

## Bundled inputs (`trace_analysis/traces/`)

Only the CSVs the three figures actually read, grouped by workload (each stored
as `.csv.gz`):

- `gapbs_pr_twitter_t8_n10000000/` — `…_all_1ms_0ms-1000ms.csv` (fig7) plus the
  `…_nonacc_all_1ms_10ms-11ms.csv` and `…_nonacc_hotlist_{lfu_ao,cms_ee}_th{32,64,96}_…csv`
  hotlists (fig2 / fig5)
- `gapbs_bc_twitter_t8_n10000000/` — `…_all_1ms_0ms-1000ms.csv` (fig7)
- `spec_502_gcc_r_c8/` — `…_all_1ms_0ms-1000ms.csv` (fig7)

The windows differ by figure: fig2 / fig5 use the 10–11 ms `nonacc` per-epoch
data, fig7 uses the 0–1000 ms cumulative data. The two groups are not
interchangeable — accumulating over 1000 ms discards the per-epoch structure
fig2/fig5 plot, and the hotlists are selector outputs (CMS is approximate) that
cannot be recomputed from exact per-page counts.

Columns are trimmed to what the figures actually read. The `_all_…` CSVs keep
`page_addr, active_time_us, access_count`; `src/cli.py pages` also emits
`w90_us`, which no figure uses, so `regenerate.sh` drops it before bundling.

## Layout

```
AE1/
├── README.md
├── THIRD_PARTY_NOTICES.md
├── cxl-tracer/              submodule — FPGA trace-collection framework (provenance)
└── trace_analysis/
    ├── README.md
    ├── regenerate.sh        rebuild traces/*.csv.gz from the raw .bin traces
    ├── parser/              vendored trace parser (src/, pdf_parser/)
    ├── traces/              bundled input CSVs (.csv.gz), grouped by workload
    ├── figure2/             figure_page_dist.py   run_fig2.sh   {expected,generated}_fig2{a,b,c}.png
    ├── figure5/             figure_th_sweep.py    run_fig5.sh   {expected,generated}_fig5{a,b}.png
    └── figure7/             figure_access_dist.py run_fig7.sh   {expected,generated}_fig7{a,b,c}.png
```

## Publication and licensing notes

See `THIRD_PARTY_NOTICES.md`. The bundled CSVs are windowed per-page counts
derived from GAPBS and SPEC CPU2017 runs; confirm redistribution permission for
the SPEC-derived inputs before making the repository public. CXL-Tracer is a
separate upstream project referenced as a submodule and carries its own license
and citation requirement.

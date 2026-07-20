# ARC custom RTL

This directory contains only the custom SystemVerilog files in the active RTL
hierarchy rooted at `hardware_test_design/common/afu/afu_top.sv`. They were
copied without source changes from:

```text
/fast-lab-share/chihuns2/CHMU/chmu_man/pof/project_chmu/
  pac_chmu_cmsketch_rev4_lfu_rev7_indv/
```

The original source-relative directory structure is preserved below `rtl/`.
Intel CXL example-design packages, generated FPGA IP, Quartus metadata, build
outputs, backup sources, and testbench databases are not included.

## RTL hierarchy

```text
afu_top
└── chmu_wrapper
    ├── axis_data_fifo × 2
    └── chmu_tracker
        ├── sampling_module
        ├── lfu_3cycle_counter_set
        ├── cm_sketch_counter
        └── hotlist
```

`afu_top` passes the memory-controller AXI channels through unchanged and
monitors channel 0. The tracker updates the LFU cache-based tracker and the
Count-Min Sketch in parallel. `counter_mode=0` selects LFU results and
`counter_mode=1` selects Count-Min Sketch results. Pages that reach the
configured hotness threshold are placed in `hotlist` and reported through the
migration-address stream.

## File descriptions

| File | Module | Description |
|---|---|---|
| `hardware_test_design/common/afu/afu_top.sv` | `afu_top` | ARC AFU boundary. Connects the CXL memory-controller AXI interface to `chmu_wrapper`, passes all AXI channels through, and exposes query, mode, threshold, migration-result, and debug interfaces. |
| `hardware_test_design/common/chmu/chmu_wrapper.sv` | `chmu_wrapper` | Converts accepted AXI read/write addresses into page addresses, buffers address/result streams, drives the tracker, and creates the debug status outputs. The current revision retains range-bound ports but forces the range match true. |
| `hardware_test_design/common/chmu/chmu_tracker.sv` | `chmu_tracker` | Request/epoch controller that sends sampled addresses to the LFU and Count-Min Sketch implementations, selects the configured counter mode, and forwards hot-page records to `hotlist`. |
| `hardware_test_design/common/chmu/sampling_module.sv` | `sampling_module` | Deterministic one-in-N access sampler. The default `SAMPLING_RATE=1` records every accepted access. |
| `hardware_test_design/common/chmu/lfu_3cycle_counter_set.sv` | `lfu_3cycle_counter_set` | Three-cycle set-associative LFU tracker. The default organization is 1,024 sets by four ways with 12-bit saturating counters and a programmable hotness threshold. |
| `hardware_test_design/common/chmu/cm_sketch_counter.sv` | `cm_sketch_counter` | Four-hash Count-Min Sketch with four 2,048-entry counter rows. Reports threshold crossings and clears valid state at epoch boundaries. |
| `hardware_test_design/common/chmu/hotlist.sv` | `hotlist` | Circular queue for hot `{page address, count}` records with occupancy, push/pop, and full-drop accounting. Historical valid/acknowledge signal names are retained. |
| `hardware_test_design/common/chmu/axis_data_fifo.sv` | `axis_data_fifo` | Ready/valid stream wrapper used for the address and migration-result paths, including near-full backpressure. |

## External integration requirements

These eight files are the custom ARC RTL, not a standalone FPGA project. The
original Intel/Quartus environment must separately provide:

- `ed_cxlip_top_pkg`, `ed_mc_axi_if_pkg`, and the CXL Type-2 definitions used
  by `afu_top` and `chmu_wrapper`.
- The `fifo_w32_d256` implementation instantiated by `axis_data_fifo`.
- The `port_2_ram` implementation instantiated by
  `lfu_3cycle_counter_set`.
- The surrounding CXL Type-2 example design, project constraints, and Quartus
  build configuration needed to produce a POF.

The Intel packages and IP are deliberately not copied into this repository.
Reviewers should use the provided POF for artifact execution; this directory is
intended to disclose and explain the custom ARC logic.

## Excluded source-project content

- Intel CXL example-design packages and generated CXL-IP files.
- Intel-generated FIFO/RAM IP descriptors, RTL, and metadata.
- Quartus databases, reports, simulation output, and other generated files.
- The stale duplicate `common/chmu/afu_top.sv`, old counter implementations,
  `common/chmu_backup_old/`, testbench work databases, and pre-fix backups.
- QSF-listed alternatives/templates not instantiated below the selected
  `afu_top`, including PLRU and legacy query-control modules.

## Licensing

Original file headers are preserved. `lfu_3cycle_counter_set.sv` carries an
Apache-2.0 notice. The requested `afu_top.sv` retains its original Intel-derived
header, while several custom CHMU files have no component-level license header.
See `THIRD_PARTY_NOTICES.md` before public redistribution.

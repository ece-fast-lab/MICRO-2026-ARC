# ARC custom RTL

This directory contains the eight custom SystemVerilog files used by ARC.
Their source-relative hierarchy is preserved below `rtl/`.
Intel CXL example-design packages, generated IP, Quartus files, and build outputs are not included.

## Hierarchy

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

`afu_top` passes the memory-controller AXI channels through and monitors channel 0.
The tracker updates the LFU and Count-Min Sketch structures in parallel.
`counter_mode=0` selects LFU, and `counter_mode=1` selects Count-Min Sketch.
Pages that reach the threshold are sent to `hotlist` for migration.

## Files

| File | Module | Purpose |
|---|---|---|
| `hardware_test_design/common/afu/afu_top.sv` | `afu_top` | Connects the CXL memory-controller interface to ARC and exposes the control and result signals. |
| `hardware_test_design/common/chmu/chmu_wrapper.sv` | `chmu_wrapper` | Converts accepted AXI requests to page addresses and connects the tracker and FIFOs. |
| `hardware_test_design/common/chmu/chmu_tracker.sv` | `chmu_tracker` | Controls requests and epochs, selects the counter mode, and forwards hot pages. |
| `hardware_test_design/common/chmu/sampling_module.sv` | `sampling_module` | Samples one in every N accepted accesses; `SAMPLING_RATE=1` records every access. |
| `hardware_test_design/common/chmu/lfu_3cycle_counter_set.sv` | `lfu_3cycle_counter_set` | Implements the set-associative LFU hotness tracker. |
| `hardware_test_design/common/chmu/cm_sketch_counter.sv` | `cm_sketch_counter` | Implements the four-hash Count-Min Sketch tracker. |
| `hardware_test_design/common/chmu/hotlist.sv` | `hotlist` | Queues hot page addresses and counts for migration. |
| `hardware_test_design/common/chmu/axis_data_fifo.sv` | `axis_data_fifo` | Provides ready/valid buffering for address and result streams. |

## External requirements

These files are not a standalone Quartus project.
The Intel development environment must provide:

- `ed_cxlip_top_pkg`, `ed_mc_axi_if_pkg`, and the CXL Type-2 definitions.
- The `fifo_w32_d256` and `port_2_ram` IP implementations.
- The surrounding CXL Type-2 example design, constraints, and Quartus project files.

Use the supplied POF files for AE2–AE4 execution.

## Licensing

Original source headers are preserved.
`lfu_3cycle_counter_set.sv` carries an Apache-2.0 notice, and `afu_top.sv` retains its Intel-derived header.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) before redistribution.

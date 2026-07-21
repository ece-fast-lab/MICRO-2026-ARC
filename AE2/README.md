# AE2 – Memory Usage and Migration Traffic (Figure 4)

AE2 reproduces Figure 4 for SPEC CPU2017 `gcc` at CHMU thresholds 32 and 96 and plots Local-memory usage, CXL-memory usage, and migration traffic over time.

## Experiment configuration

| Item | Value |
|---|---|
| Benchmark | SPEC CPU2017 `gcc` (`502`), 8 copies |
| CHMU mode | Cache-only, epoch `400000/400000` |
| Thresholds | 32 and 96 |
| Polling interval | 1 ms |
| Placement | Node 1 (CXL) to Node 0 (Local) |
| Warmup | 10 s before migration starts |
| Raw sampling | 5 s using `numastat -c base` and `/proc/vmstat` |
| FPGA image | `chmu_ae_merge_SPL1` |

## Prerequisites

Use the dedicated AE host with PCI device `8086:0ddb`, Node 0 as Local memory, and Node 1 as CXL memory. Run all commands from the reviewer account because the scripts invoke `sudo` only for privileged operations. Do not use `sudo -i` or prefix an entire command with `sudo`. Install SPEC CPU2017 separately because it is not included in this artifact.

The AE host must run kernel `6.11.0-mig-offload+` with these boot arguments:

```text
intel_iommu=on,sm_on iommu=pt no5lvl efi=nosoftreserve memmap=124G$0x180000000
```

Use the [custom-kernel guide](../kernel/README.md) if the target host has not been provisioned.

## Reproduce Figure 4

Run `cd AE2` from the repository root before following these steps.

### 1. Program the FPGA

Run these commands on the FPGA programming server:

```bash
unzip -o program_script/chmu_ae_merge_SPL1.zip -d program_script
bash program_script/update_cdf_paths.sh
bash program_script/program_spr1.sh chmu_ae_merge_SPL1.cdf
```

Ask the authorized system operator to power-cycle the AE host because BMC credentials are not included. Reconnect after the target host finishes booting, and verify the kernel and NUMA topology:

```bash
uname -r
numactl -H
```

`uname -r` must print `6.11.0-mig-offload+`, and `numactl -H` must show both memory nodes.

### 2. Set the SPEC CPU2017 paths

Edit this file on the target host:

```text
sw/config/benchmark_paths.env
```

Set `SPEC_ROOT`, `SPEC_RUNCPU`, and the absolute `SPEC_CONFIG` path.

### 3. Configure the target host

```bash
bash set_default/setup_default.sh all
```

This command configures the target host but does not start the benchmark.

### 4. Collect threshold 32 and 96 data

```bash
./sw/build_option_th32/run_fig4_th32.sh all yes --skip-plot
./sw/build_option_th96/run_fig4_th96.sh all yes --skip-plot
```

Each command runs `gcc`, converts `debug_monitor.log`, and skips Matplotlib plotting. If a result already exists, the command moves it to `.bak` or `.bak.N` before rerunning.

### 5. Plot the existing logs

These commands reuse the existing logs and do not rerun `gcc`:

```bash
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  ./sw/build_option_th32/run_fig4_th32.sh --skip-benchmark --yes
env PYTHONNOUSERSITE=1 \
  PYTHONPATH=/usr/lib/python3/dist-packages \
  ./sw/build_option_th96/run_fig4_th96.sh --skip-benchmark --yes
```

## Results

The result directories are:

```text
sw/build_option_th32/output/32_400000_400000_1_502_mig_fig4_gcc_cache/
sw/build_option_th96/output/96_400000_400000_1_502_mig_fig4_gcc_cache/
```

Each directory contains these primary files:

| File | Contents |
|---|---|
| `debug_monitor.log` | Raw 5-second monitor samples |
| `debug_monitor.log.txt` | Converted one-second CSV data |
| `memory_usage_migration_traffic.png` | 300-DPI plot |
| `memory_usage_migration_traffic.pdf` | Vector plot |

The plot reports Node 0 as Local Memory, Node 1 as CXL Memory, and migration traffic from `pgmigrate_success` with a 4 KiB page size. Collect data while the AE host is idle because the input counters are system-wide. Threshold 32 should show more frequent migration traffic than threshold 96. The plotter uses axis maxima of at least 1000 s, 8 GiB, and 800 MB/s.

## Troubleshooting

Run the preflight check before changing host state:

```bash
bash set_default/setup_default.sh check
```

If platform detection is ambiguous, provide the reference-platform values explicitly:

```bash
PCIE_BDF=0000:40:00.1 CXL_NODE=1 BUFFER_NODE=0 \
  bash set_default/setup_default.sh all
```

If `apply` fails, reboot the target host before collecting results.

If Matplotlib is unavailable, install `sw/fig4/requirements.txt` in an isolated Python environment and rerun the plotting commands.

## Cleanup

```bash
bash set_default/setup_default.sh disable
```

## References

- [Custom kernel](../kernel/README.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Bundled module provenance](sw/prebuilt_module_source/README.md)

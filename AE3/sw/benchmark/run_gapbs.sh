#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SW_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_DIR="$(cd -- "${SW_DIR}/.." && pwd)"

if [[ $# -lt 7 ]]; then
  echo "Usage: $0 <cnt_th> <epoch_cycle_a> <epoch_cycle_b> <poll_ms> <benchmark> <db> <mode> [tag]"
  exit 1
fi

DEFAULT_CONFIG_FILE="${DEFAULT_CONFIG_FILE:-${ARTIFACT_DIR}/set_default/config/defaults.env}"
# shellcheck source=/dev/null
source "${DEFAULT_CONFIG_FILE}"
actual_hostname="$(hostname -s)"
if [[ "${actual_hostname}" != "${EXPECTED_HOSTNAME}" && "${ALLOW_NON_SPR1}" != 1 ]]; then
  echo "ERROR: this benchmark is restricted to ${EXPECTED_HOSTNAME}; current host is ${actual_hostname}" >&2
  exit 1
fi
if [[ "$(uname -r)" != "${EXPECTED_KERNEL_RELEASE}" ]]; then
  echo "ERROR: running kernel $(uname -r) does not match ${EXPECTED_KERNEL_RELEASE}" >&2
  exit 1
fi
for cmdline_token in \
  'intel_iommu=on,sm_on' 'iommu=pt' 'no5lvl' 'efi=nosoftreserve' \
  "memmap=${REQUIRED_MEMMAP}"; do
  if ! tr ' ' '\n' < /proc/cmdline | grep -Fxq -- "${cmdline_token}"; then
    echo "ERROR: required kernel command-line token is missing: ${cmdline_token}" >&2
    exit 1
  fi
done

BENCHMARK_PATHS_FILE="${BENCHMARK_PATHS_FILE:-${SW_DIR}/config/benchmark_paths.env}"
if [[ ! -f "${BENCHMARK_PATHS_FILE}" ]]; then
  echo "ERROR: benchmark path configuration not found: ${BENCHMARK_PATHS_FILE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${BENCHMARK_PATHS_FILE}"
PLATFORM_CONFIG_FILE="${PLATFORM_CONFIG_FILE:-${SW_DIR}/../set_default/generated/platform.env}"
if [[ ! -f "${PLATFORM_CONFIG_FILE}" ]]; then
  echo "ERROR: platform configuration not found: ${PLATFORM_CONFIG_FILE}" >&2
  echo "Run: ${SW_DIR}/../set_default/setup_default.sh detect" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${PLATFORM_CONFIG_FILE}"

# Usage:
#   SRC_NODE=1 DST_NODE=0 \
#   WL_CPUS=0-7 MIGRATION_CPU=20 \
#   ./run_gapbs.sh <cnt_th> <epoch_cycle_a> <epoch_cycle_b> <poll_ms> <benchmark> <db> <mode> [tag]
#
# mode:
#   baseline : no CHMU, no ANB, no DAMON, demotion=0
#              BASELINE_START_MEMS controls initial cpuset.mems
#              BASELINE_MEMS controls post-start cpuset.mems
#              BASELINE_MEM_POLICY=interleave adds numactl --interleave
#              BASELINE_MEM_POLICY=membind adds numactl --membind
#   mig      : CHMU migration via migration_manager, demotion=1
#   anb      : enable Auto NUMA Balancing, demotion=1
#   damon    : start DAMON migrate_hot, demotion=1

cnt_th="$1"
epoch_cycle_a="$2"
epoch_cycle_b="$3"
poll_ms="$4"
benchmark="$5"
graph_db="$6"
mode="$7"
tag="${8:-$(TZ=America/Chicago date +%Y%m%d_%H%M%S)}"

case "${cnt_th}" in
  16|32|64|96) ;;
  *) echo "ERROR: cnt_th must be one of: 16 | 32 | 64 | 96"; exit 1 ;;
esac
[[ "${epoch_cycle_a}" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]] || \
  { echo "ERROR: epoch_cycle_a must be an unsigned integer"; exit 1; }
[[ "${epoch_cycle_b}" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]] || \
  { echo "ERROR: epoch_cycle_b must be an unsigned integer"; exit 1; }
[[ "${poll_ms}" =~ ^[1-9][0-9]*$ ]] || \
  { echo "ERROR: poll_ms must be a positive decimal integer"; exit 1; }
[[ "${tag}" =~ ^[A-Za-z0-9._-]+$ ]] || \
  { echo "ERROR: tag may contain only letters, digits, dot, underscore, and dash"; exit 1; }
[[ "${CHMU_ALLOW_PREDICTOR_FALLBACK:-0}" =~ ^[01]$ ]] || \
  { echo "ERROR: CHMU_ALLOW_PREDICTOR_FALLBACK must be 0 or 1"; exit 1; }
[[ "${MIGRATION_START_GATE_TIMEOUT_SEC:-30}" =~ ^[1-9][0-9]*$ ]] || \
  { echo "ERROR: MIGRATION_START_GATE_TIMEOUT_SEC must be a positive decimal integer"; exit 1; }
[[ "${MIGRATION_START_TIMEOUT_SEC:-10}" =~ ^[1-9][0-9]*$ ]] || \
  { echo "ERROR: MIGRATION_START_TIMEOUT_SEC must be a positive decimal integer"; exit 1; }
[[ "${MIGRATION_STOP_GRACE_SEC:-10}" =~ ^[1-9][0-9]*$ ]] || \
  { echo "ERROR: MIGRATION_STOP_GRACE_SEC must be a positive decimal integer"; exit 1; }

case "$benchmark" in
  bc|bfs|cc|pr) ;;
  *) echo "ERROR: benchmark must be one of: bc | bfs | cc | pr"; exit 1 ;;
esac

case "$graph_db" in
  web|twitter) ;;
  *) echo "ERROR: db must be one of: web | twitter"; exit 1 ;;
esac

case "$mode" in
  baseline|mig|anb|damon) ;;
  *) echo "ERROR: mode must be one of: baseline | mig | anb | damon"; exit 1 ;;
esac

# ---- Paths (override in sw/config/benchmark_paths.env) ----
SET_PARA_DIR="${SET_PARA_DIR:-${SW_DIR}/set_para}"
GAPBS_DIR="${GAPBS_DIR:-${GAPBS_ROOT:?Set GAPBS_ROOT in ${BENCHMARK_PATHS_FILE}}}"
GAPBS_GRAPH_DIR="${GAPBS_GRAPH_DIR:-${GAPBS_DIR}/benchmark/graphs}"
GAPBS_WEB_GRAPH="${GAPBS_WEB_GRAPH:-}"
GAPBS_TWITTER_GRAPH="${GAPBS_TWITTER_GRAPH:-}"
MIGRATION_MANAGER_DIR="${MIGRATION_MANAGER_DIR:-${SW_DIR}/build_option_th${cnt_th}}"
OUT_BASE_DIR="${OUT_BASE_DIR:-${MIGRATION_MANAGER_DIR}/output}"
PQOS_SH="${PQOS_SH:-${SW_DIR}/core_pqos/set_8t_llc.sh}"
KMOD_PGMIGRATE_DIR="${KMOD_PGMIGRATE_DIR:-${SW_DIR}/kmod_pgmigrate}"
# --------------------------------

# ---- knobs (override via env) ----
SRC_NODE="${SRC_NODE:-${CXL_NODE:-1}}"
DST_NODE="${DST_NODE:-${BUFFER_NODE:-0}}"

WL_CPUS="${WL_CPUS:-0-7}"
MIGRATION_CPU="${MIGRATION_CPU:-20}"
DBG_INTERVAL_SEC="${DBG_INTERVAL_SEC:-1}"
ENABLE_DEBUG_MONITOR="${ENABLE_DEBUG_MONITOR:-0}"
OMP_THREADS="${OMP_THREADS:-8}"

PHASE1_SEC="${PHASE1_SEC:-10}"
ANB_VALUE="${ANB_VALUE:-2}"

# migration_manager dedup window (recent PFNs tracked). 0 => unlimited (not recommended)
MIGRATION_MAX_MIGRATED_PFNS="${MIGRATION_MAX_MIGRATED_PFNS:-250000}"
MIGRATION_PREDICTOR_INTERVAL_MS="${MIGRATION_PREDICTOR_INTERVAL_MS:-10}"
CHMU_ENABLE_FEATURE_TRACE="${CHMU_ENABLE_FEATURE_TRACE:-0}"

# 1: disable at start (recommended for clean phase-1 pinning)
DISABLE_NUMA_BAL="${DISABLE_NUMA_BAL:-1}"
DISABLE_THP="${DISABLE_THP:-1}"

# reclaim loop knobs (for mig mode)
RECLAIM_LOOP_ENABLE="${RECLAIM_LOOP_ENABLE:-1}"
LOCAL_FREE_LOW_MB="${LOCAL_FREE_LOW_MB:-256}"      # local free < 256MB => reclaim trigger
RECLAIM_AMOUNT_MB="${RECLAIM_AMOUNT_MB:-128}"      # each memory.reclaim request
RECLAIM_CHECK_SEC="${RECLAIM_CHECK_SEC:-1}"        # polling interval
RECLAIM_COOLDOWN_SEC="${RECLAIM_COOLDOWN_SEC:-1}"  # sleep right after reclaim
MIGRATION_RECLAIM_DISABLE_AFTER_SEC="${MIGRATION_RECLAIM_DISABLE_AFTER_SEC:-1000}"  # 0 => never auto-stop
MIGRATION_START_TIMEOUT_SEC="${MIGRATION_START_TIMEOUT_SEC:-10}"
MIGRATION_STOP_GRACE_SEC="${MIGRATION_STOP_GRACE_SEC:-10}"
MIGRATION_START_GATE_TIMEOUT_SEC="${MIGRATION_START_GATE_TIMEOUT_SEC:-30}"
CHMU_ALLOW_PREDICTOR_FALLBACK="${CHMU_ALLOW_PREDICTOR_FALLBACK:-0}"

# turn off demotion once *_r_base tasks disappear from the workload cgroup
DEMOTION_DISABLE_ON_RBASE_EXIT="${DEMOTION_DISABLE_ON_RBASE_EXIT:-1}"
R_BASE_EXIT_PATTERN="${R_BASE_EXIT_PATTERN:-_r_base}"
WORKLOAD_FINISH_ON_RBASE_EXIT="${WORKLOAD_FINISH_ON_RBASE_EXIT:-1}"
R_BASE_EXIT_GRACE_SEC="${R_BASE_EXIT_GRACE_SEC:-15}"
WORKLOAD_TERM_TIMEOUT_SEC="${WORKLOAD_TERM_TIMEOUT_SEC:-5}"
STOP_NODE0="${STOP_NODE0:-0}"
STOP_NODE1="${STOP_NODE1:-1}"

# DAMON knobs
DAMON_ALSO_ENABLE_ANB="${DAMON_ALSO_ENABLE_ANB:-0}"   # 1 => also set numa_balancing=ANB_VALUE when mode=damon
DAMON_TARGET_NODE="${DAMON_TARGET_NODE:-$DST_NODE}"   # typically 0 (local)

# Use DAMO tool for DAMON control
DAMO_BIN="${DAMO_BIN:-}"
DAMO_CONFIG="${DAMO_CONFIG:-}"
DAMO_REPORT_KIND="${DAMO_REPORT_KIND:-damon}"

# IMPORTANT: put cgroup under ROOT (not user session scope)
CGROUP_ROOT="/sys/fs/cgroup"
CGROUP_NAME="${CGROUP_NAME:-app}"
CGROUP_PATH="${CGROUP_ROOT}/${CGROUP_NAME}"

if [[ -z "${BASELINE_MEMS:-}" ]]; then
  BASELINE_MEMS="${SRC_NODE}"
  if [[ "$mode" == "baseline" ]] && [[ "$SRC_NODE" != "$DST_NODE" ]]; then
    BASELINE_MEMS="${SRC_NODE},${DST_NODE}"
  fi
fi
BASELINE_START_MEMS="${BASELINE_START_MEMS:-$BASELINE_MEMS}"
BASELINE_MEM_POLICY="${BASELINE_MEM_POLICY:-default}"
BASELINE_EXPAND_DELAY_SEC="${BASELINE_EXPAND_DELAY_SEC:-2}"
case "$BASELINE_MEM_POLICY" in
  default|interleave|membind) ;;
  *) echo "ERROR: BASELINE_MEM_POLICY must be one of: default | interleave | membind"; exit 1 ;;
esac

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO="${SUDO:-}"
else
  SUDO="${SUDO:-sudo}"
fi
ARC_LOCK_FILE="${ARC_LOCK_FILE:-/run/lock/micro_2026_arc.lock}"
ARC_LOCK_HELD=0
# ---------------------------------

# shellcheck source=manager_runtime.sh
source "${SCRIPT_DIR}/manager_runtime.sh"
# shellcheck source=runner_controls.sh
source "${SCRIPT_DIR}/runner_controls.sh"

acquire_exclusive_lock() {
  command -v flock >/dev/null 2>&1 || { echo "ERROR: flock is required" >&2; exit 1; }
  if [[ -n "${ARC_LOCK_BUSY_MARKER:-}" ]]; then
    rm -f -- "${ARC_LOCK_BUSY_MARKER}" 2>/dev/null || true
  fi
  if [[ ! -e "${ARC_LOCK_FILE}" ]]; then
    (umask 000; set -o noclobber; : > "${ARC_LOCK_FILE}") 2>/dev/null || true
  fi
  exec 9<"${ARC_LOCK_FILE}" || { echo "ERROR: cannot open lock ${ARC_LOCK_FILE}" >&2; exit 1; }
  if ! flock -n 9; then
    if [[ -n "${ARC_LOCK_BUSY_MARKER:-}" ]]; then
      (umask 077; : > "${ARC_LOCK_BUSY_MARKER}") 2>/dev/null || true
    fi
    echo "ERROR: another ARC setup or benchmark command is active" >&2
    exit 1
  fi
  ARC_LOCK_HELD=1
}

release_exclusive_lock() {
  [[ "${ARC_LOCK_HELD:-0}" == "1" ]] || return 0

  # Background jobs and the process-substitution tee inherit FD 9.  Closing
  # only the parent shell's descriptor can therefore leave the host-wide lock
  # held after a completed case.  Explicit LOCK_UN applies to the shared open
  # file description, so the next case can start as soon as cleanup finishes.
  flock -u 9 2>/dev/null || true
  exec 9<&-
  ARC_LOCK_HELD=0
}

resolve_gapbs_graph() {
  local db="$1"
  local cand
  local candidates=()

  case "$db" in
    web)
      candidates=(
        "$GAPBS_WEB_GRAPH"
        "${GAPBS_GRAPH_DIR}/web.sg"
        "${GAPBS_GRAPH_DIR}/web.wsg"
        "${GAPBS_GRAPH_DIR}/web/web.sg"
        "${GAPBS_GRAPH_DIR}/web/web.wsg"
        "${GAPBS_GRAPH_DIR}/gplus/gplus/imc12/direct_social_structure.wel"
      )
      ;;
    twitter)
      candidates=(
        "$GAPBS_TWITTER_GRAPH"
        "${GAPBS_GRAPH_DIR}/twitter.sg"
        "${GAPBS_GRAPH_DIR}/twitter/twitter.sg"
      )
      ;;
    *)
      return 1
      ;;
  esac

  for cand in "${candidates[@]}"; do
    [[ -n "$cand" ]] || continue
    if [[ -e "$cand" ]]; then
      echo "$cand"
      return 0
    fi
  done

  return 1
}

build_gapbs_cmd() {
  GAPBS_CMD=("$GAPBS_BIN" -f "$GAPBS_GRAPH_PATH")

  case "$benchmark" in
    bc)
      GAPBS_CMD+=(-n10)
      ;;
    bfs)
      GAPBS_CMD+=(-n10)
      ;;
    cc)
      GAPBS_CMD+=(-n10)
      ;;
    pr)
      GAPBS_CMD+=(-n10)
      ;;
  esac
}

rotate_if_exists() {
  local p="$1"
  [[ -e "$p" ]] || return 0
  local i=0
  while [[ -e "${p}.bak${i}" ]]; do i=$((i+1)); done
  mv "$p" "${p}.bak${i}"
}

rotate_dir_if_exists() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  local i=0
  while [[ -d "${d}.bak${i}" ]]; do i=$((i+1)); done
  mv "$d" "${d}.bak${i}"
}

ensure_page_migrate_loaded() {
  local attempt
  local insmod_output=""

  for attempt in 1 2 3 4 5; do
    if lsmod | grep -q "^page_migrate"; then
      return 0
    fi
    if [[ -e "/proc/cxl_migrate_node" && -e "/proc/cxl_migrate_pfn" ]]; then
      echo "[module] page_migrate proc nodes already exist; continue"
      return 0
    fi
    echo "[module] page_migrate not visible yet (attempt ${attempt}/5); wait 1s"
    sleep 1
  done

  local module_ko="${KMOD_PGMIGRATE_DIR}/page_migrate.ko"
  [[ -e "$module_ko" ]] || {
    echo "ERROR: page_migrate module file not found: $module_ko"
    return 1
  }

  echo "[module] page_migrate not loaded. loading from ${module_ko}"
  insmod_output="$($SUDO insmod "$module_ko" 2>&1)" || {
    if [[ "$insmod_output" == *"File exists"* ]]; then
      echo "[module] insmod reported 'File exists'; re-check module readiness"
    else
      echo "$insmod_output"
      echo "ERROR: failed to insmod page_migrate from ${module_ko}"
      return 1
    fi
  }

  for attempt in 1 2 3 4 5; do
    if lsmod | grep -q "^page_migrate"; then
      echo "[module] page_migrate loaded successfully"
      return 0
    fi
    if [[ -e "/proc/cxl_migrate_node" && -e "/proc/cxl_migrate_pfn" ]]; then
      echo "[module] page_migrate proc nodes appeared after insmod"
      return 0
    fi
    sleep 1
  done

  echo "ERROR: page_migrate still not ready after insmod"
  return 1
}

acquire_exclusive_lock
trap release_exclusive_lock EXIT
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  sudo -v
fi
[[ "$CGROUP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
  echo "ERROR: CGROUP_NAME must start with a letter or digit and contain only letters, digits, dot, underscore, and dash" >&2
  exit 1
}
runner_assert_cgroup_empty

RUN_OUT_DIR="${OUT_BASE_DIR}/${cnt_th}_${epoch_cycle_a}_${epoch_cycle_b}_${poll_ms}_${benchmark}_${graph_db}_${mode}_${tag}"
rotate_dir_if_exists "$RUN_OUT_DIR"
mkdir -p "$RUN_OUT_DIR"

LOG_FILE="${RUN_OUT_DIR}.log"
rotate_if_exists "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==== $(TZ=America/Chicago date) ===="
echo "mode=$mode benchmark=$benchmark db=$graph_db tag=$tag"
echo "epoch_cycle_a=$epoch_cycle_a epoch_cycle_b=$epoch_cycle_b poll_ms=$poll_ms"
echo "SRC_NODE=$SRC_NODE DST_NODE=$DST_NODE"
echo "WL_CPUS=$WL_CPUS MIGRATION_CPU=$MIGRATION_CPU OMP_THREADS=$OMP_THREADS PHASE1_SEC=$PHASE1_SEC"
echo "MIGRATION_MAX_MIGRATED_PFNS=$MIGRATION_MAX_MIGRATED_PFNS"
echo "MIGRATION_PREDICTOR_INTERVAL_MS=$MIGRATION_PREDICTOR_INTERVAL_MS"
echo "RECLAIM_LOOP_ENABLE=$RECLAIM_LOOP_ENABLE LOCAL_FREE_LOW_MB=$LOCAL_FREE_LOW_MB RECLAIM_AMOUNT_MB=$RECLAIM_AMOUNT_MB"
echo "MIGRATION_RECLAIM_DISABLE_AFTER_SEC=$MIGRATION_RECLAIM_DISABLE_AFTER_SEC"
echo "DEMOTION_DISABLE_ON_RBASE_EXIT=$DEMOTION_DISABLE_ON_RBASE_EXIT R_BASE_EXIT_PATTERN=$R_BASE_EXIT_PATTERN"
echo "WORKLOAD_FINISH_ON_RBASE_EXIT=$WORKLOAD_FINISH_ON_RBASE_EXIT R_BASE_EXIT_GRACE_SEC=$R_BASE_EXIT_GRACE_SEC WORKLOAD_TERM_TIMEOUT_SEC=$WORKLOAD_TERM_TIMEOUT_SEC"
echo "STOP_NODE0=$STOP_NODE0 STOP_NODE1=$STOP_NODE1"
echo "BASELINE_START_MEMS=$BASELINE_START_MEMS BASELINE_MEMS=$BASELINE_MEMS BASELINE_MEM_POLICY=$BASELINE_MEM_POLICY BASELINE_EXPAND_DELAY_SEC=$BASELINE_EXPAND_DELAY_SEC"
echo "CGROUP_PATH=$CGROUP_PATH"
echo

# sanity
[[ -d "$SET_PARA_DIR" ]] || { echo "ERROR: SET_PARA_DIR not found: $SET_PARA_DIR"; exit 1; }
[[ -d "$GAPBS_DIR" ]] || { echo "ERROR: GAPBS_DIR not found: $GAPBS_DIR"; exit 1; }
[[ -x "$MIGRATION_MANAGER_DIR/migration_manager" ]] || { echo "ERROR: migration_manager not found/executable: $MIGRATION_MANAGER_DIR/migration_manager"; exit 1; }
[[ "${CHMU_PERF_BIN}" == /* && -x "${CHMU_PERF_BIN}" ]] || { echo "ERROR: CHMU_PERF_BIN must be an executable absolute path: ${CHMU_PERF_BIN}"; exit 1; }

GAPBS_BIN="${GAPBS_DIR}/${benchmark}"
[[ -x "$GAPBS_BIN" ]] || { echo "ERROR: GAPBS binary not executable: $GAPBS_BIN"; exit 1; }

GAPBS_GRAPH_PATH="$(resolve_gapbs_graph "$graph_db" || true)"
[[ -n "$GAPBS_GRAPH_PATH" ]] || {
  echo "ERROR: graph path for db='${graph_db}' not found under ${GAPBS_GRAPH_DIR}"
  echo "       Override with GAPBS_WEB_GRAPH or GAPBS_TWITTER_GRAPH if needed."
  exit 1
}

GAPBS_CMD=()
build_gapbs_cmd
echo "GAPBS_BIN=$GAPBS_BIN"
echo "GAPBS_GRAPH_PATH=$GAPBS_GRAPH_PATH"

if [[ "$mode" == "mig" ]]; then
  ensure_page_migrate_loaded || exit 1
  [[ -e "/proc/cxl_migrate_node" ]] || { echo "ERROR: /proc/cxl_migrate_node not found"; exit 1; }
  [[ -e "/proc/cxl_migrate_pfn"  ]] || { echo "ERROR: /proc/cxl_migrate_pfn not found"; exit 1; }
  [[ -e "/proc/pac_ofw_buf" ]] || {
    echo "ERROR: /proc/pac_ofw_buf not found; run set_default/setup_default.sh apply" >&2
    exit 1
  }
fi

if [[ "$mode" == "damon" ]]; then
  [[ -x "$DAMO_BIN" ]] || { echo "ERROR: DAMO_BIN not found/executable: $DAMO_BIN"; exit 1; }
fi

ORIG_NUMA_BAL="$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo 0)"
ORIG_DEMOTION_ENABLED="$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo "")"

WORKLOAD_PID=""
MIGRATION_PID=""
MIGRATION_JOB_PID=""
MIGRATION_EXIT_COLLECTED="0"
MIGRATION_EXIT_RC=""
MANAGER_FAILED="0"
MIGRATION_READY_FILE="${RUN_OUT_DIR}/migration_manager.ready"
MIGRATION_START_FILE="${RUN_OUT_DIR}/migration_manager.start"
ARTIFACT_RUN_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ARTIFACT_RUN_GROUP="$(id -gn "${ARTIFACT_RUN_USER}")"
MANAGER_RUNTIME_ARCHIVE="${RUN_OUT_DIR}/manager_runtime"
CHMU_RUNTIME_DIR=""
MON_PID=""
RECLAIM_PID=""
MIG_DISABLE_MON_PID=""
SUDO_KEEPALIVE_PID=""
BACKGROUND_FAILED="0"
BACKGROUND_ERROR_FILE="${RUN_OUT_DIR}/background_error.log"
TRACKER_DISABLE_FAILED="0"
DAMON_STARTED="0"
CLEANUP_DONE="0"

manager_remove_ready_file
if [[ "$mode" == "mig" ]]; then
  CHMU_RUNTIME_DIR="$(manager_run_root mktemp -d /run/micro_2026_arc_manager.XXXXXX)"
  mkdir -m 700 -p "$MANAGER_RUNTIME_ARCHIVE"
  chmod 700 "$MANAGER_RUNTIME_ARCHIVE"
fi

INIT_USED_NODE0_KB=""
INIT_USED_NODE1_KB=""
WORKLOAD_START_TS=""
WORKLOAD_WAIT_RC=""

cleanup() {
  if [[ "${CLEANUP_DONE}" == "1" ]]; then
    return 0
  fi
  CLEANUP_DONE="1"

  echo "[cleanup] begin"

  if [[ -n "${MON_PID:-}" ]] && kill -0 "$MON_PID" 2>/dev/null; then
    kill "$MON_PID" 2>/dev/null || true
    wait "$MON_PID" 2>/dev/null || true
  fi

  if [[ -n "${RECLAIM_PID:-}" ]] && kill -0 "$RECLAIM_PID" 2>/dev/null; then
    kill "$RECLAIM_PID" 2>/dev/null || true
    wait "$RECLAIM_PID" 2>/dev/null || true
  fi

  if [[ -n "${MIG_DISABLE_MON_PID:-}" ]] && kill -0 "$MIG_DISABLE_MON_PID" 2>/dev/null; then
    kill "$MIG_DISABLE_MON_PID" 2>/dev/null || true
    wait "$MIG_DISABLE_MON_PID" 2>/dev/null || true
  fi

  if [[ "$mode" == "mig" ]]; then
    manager_stop "runner cleanup" || true
  fi

  if [[ -n "${WORKLOAD_PID:-}" ]] && kill -0 "$WORKLOAD_PID" 2>/dev/null; then
    terminate_workload_cgroup "cleanup"
    wait "$WORKLOAD_PID" 2>/dev/null || true
  fi

  if [[ "$DAMON_STARTED" == "1" ]]; then
    echo "==== [cleanup] damo stop ===="
    $SUDO "$DAMO_BIN" stop 2>&1 || true
    echo "==== [cleanup] damo report (after stop) ===="
    $SUDO "$DAMO_BIN" report "$DAMO_REPORT_KIND" 2>&1 || true
  fi

  echo "[cleanup] disabling CHMU tracking"
  bash "${SET_PARA_DIR}/tracker.sh" disable >/dev/null 2>&1 || true

  echo "$ORIG_NUMA_BAL" | $SUDO tee /proc/sys/kernel/numa_balancing >/dev/null 2>&1 || true
  echo "[cleanup] restoring numa_balancing=$ORIG_NUMA_BAL"

  if [[ -n "${ORIG_DEMOTION_ENABLED}" ]] && [[ -e /sys/kernel/mm/numa/demotion_enabled ]]; then
    echo "$ORIG_DEMOTION_ENABLED" | $SUDO tee /sys/kernel/mm/numa/demotion_enabled >/dev/null 2>&1 || true
    echo "[cleanup] restoring demotion_enabled=$ORIG_DEMOTION_ENABLED"
  fi

  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi

  echo "[cleanup] end"
}

trap 'cleanup; release_exclusive_lock' EXIT
trap 'echo "[signal] interrupted"; cleanup; exit 130' INT TERM

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  runner_checked_background sudo_keepalive runner_sudo_keepalive &
  SUDO_KEEPALIVE_PID=$!
fi

echo "==== Apply pqos config ===="
if [[ "${SKIP_CPU_ISOLATION:-0}" == "1" ]]; then
  echo "[cpu] SKIP_CPU_ISOLATION=1; CPU offlining and LLC allocation skipped"
else
  bash "$PQOS_SH"
fi
echo

echo "==== Disable numa balancing & THP (for clean comparison phase-1) ===="
if [[ "$DISABLE_NUMA_BAL" == "1" ]]; then
  runner_write_exact /proc/sys/kernel/numa_balancing 0
fi
if [[ "$DISABLE_THP" == "1" ]]; then
  runner_set_thp_never /sys/kernel/mm/transparent_hugepage/enabled
  runner_set_thp_never /sys/kernel/mm/transparent_hugepage/defrag
fi
echo

cg_write() {
  local val="$1"
  local file="$2"
  echo "$val" | $SUDO tee "$file" >/dev/null
}

node_mem_field_kb() {
  local nid="$1"
  local field="$2"
  local meminfo="/sys/devices/system/node/node${nid}/meminfo"

  [[ -r "$meminfo" ]] || return 1

  awk -v key="${field}:" '
    index($0, key) {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+$/) {
          print $i
          exit
        }
      }
    }
  ' "$meminfo"
}

node_memfree_kb() {
  local nid="${1:-$DST_NODE}"
  node_mem_field_kb "$nid" "MemFree"
}

node_memused_kb() {
  local nid="$1"
  node_mem_field_kb "$nid" "MemUsed"
}

abs_diff_kb() {
  local a="$1"
  local b="$2"
  local d=$((a - b))
  if (( d < 0 )); then
    d=$(( -d ))
  fi
  echo "$d"
}

memcg_reclaim_once() {
  local amount_mb="${1:-$RECLAIM_AMOUNT_MB}"
  local reclaim_file="${CGROUP_PATH}/memory.reclaim"

  [[ -e "$reclaim_file" ]] || {
    echo "[reclaim] memory.reclaim not found: $reclaim_file"
    return 1
  }

  echo "${amount_mb}M" | $SUDO tee "$reclaim_file" >/dev/null
}

pid_state() {
  local pid="$1"

  [[ -r "/proc/${pid}/stat" ]] || return 1
  awk '{print $3}' "/proc/${pid}/stat"
}

pid_is_running_non_zombie() {
  local pid="$1"
  local state

  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  state="$(pid_state "$pid" 2>/dev/null || true)"
  [[ -n "$state" ]] && [[ "$state" != "Z" ]]
}

cgroup_member_pids() {
  [[ -r "${CGROUP_PATH}/cgroup.procs" ]] || return 0
  sort -u "${CGROUP_PATH}/cgroup.procs" 2>/dev/null || true
}

kill_cgroup_members() {
  local sig="$1"
  local pid

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "-${sig}" "$pid" 2>/dev/null || true
  done < <(cgroup_member_pids)
}

terminate_workload_cgroup() {
  local reason="$1"
  local pid
  local state

  echo "[workload] terminating cgroup tasks: ${reason}"
  kill_cgroup_members TERM
  sleep "$WORKLOAD_TERM_TIMEOUT_SEC"

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    state="$(pid_state "$pid" 2>/dev/null || true)"
    if [[ -n "$state" ]] && [[ "$state" != "Z" ]]; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done < <(cgroup_member_pids)
}

cgroup_pattern_pids() {
  local pattern="$1"
  local pid
  local state

  command -v pgrep >/dev/null 2>&1 || return 1

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ -r "/proc/${pid}/cgroup" ]] || continue
    state="$(pid_state "$pid" 2>/dev/null || true)"
    [[ -n "$state" ]] || continue
    [[ "$state" == "Z" ]] && continue

    if grep -Fxq "0::/${CGROUP_NAME}" "/proc/${pid}/cgroup" 2>/dev/null; then
      echo "$pid"
    fi
  done < <(pgrep -f -- "$pattern" 2>/dev/null || true)
}

wait_for_workload_exit() {
  local wait_rc=0
  local collect_rc=0
  local r_base_seen_local="0"
  local r_base_gone_ts=""
  local now_ts
  local r_base_pids

  while true; do
    if ! pid_is_running_non_zombie "$WORKLOAD_PID"; then
      break
    fi

    if [[ -s "$BACKGROUND_ERROR_FILE" ]]; then
      BACKGROUND_FAILED=1
      echo "ERROR: a benchmark control process failed:" >&2
      cat "$BACKGROUND_ERROR_FILE" >&2
      terminate_workload_cgroup "background benchmark control failed"
      break
    fi

    if [[ "$mode" == "mig" && "${MIGRATION_EXIT_COLLECTED:-0}" != 1 ]] &&
       ! manager_is_active "${MIGRATION_PID:-}"; then
      if manager_collect_exit; then
        if [[ "${MIGRATION_EXIT_RC}" != 0 ]]; then
          echo "ERROR: migration_manager exited during workload (rc=${MIGRATION_EXIT_RC})" >&2
          [[ -r "${MIGRATION_LOG:-}" ]] && tail -n 120 "$MIGRATION_LOG" >&2
          MANAGER_FAILED=1
          terminate_workload_cgroup "migration_manager failed"
          break
        fi
        echo "[manager] migration_manager completed cleanly before workload exit"
        bash "${SET_PARA_DIR}/tracker.sh" disable || {
          MANAGER_FAILED=1
          terminate_workload_cgroup "failed to disable CHMU after manager completion"
          break
        }
      else
        collect_rc=$?
        if (( collect_rc == 2 )); then
          MANAGER_FAILED=1
          terminate_workload_cgroup "migration_manager identity mismatch"
          break
        fi
      fi
    fi

    if [[ "$WORKLOAD_FINISH_ON_RBASE_EXIT" == "1" ]]; then
      r_base_pids="$(cgroup_pattern_pids "$R_BASE_EXIT_PATTERN" 2>/dev/null || true)"

      if [[ -n "$r_base_pids" ]]; then
        r_base_seen_local="1"
        r_base_gone_ts=""
      elif [[ "$r_base_seen_local" == "1" ]]; then
        now_ts="$(date +%s)"

        if [[ -z "$r_base_gone_ts" ]]; then
          r_base_gone_ts="$now_ts"
          echo "[wait] pattern '${R_BASE_EXIT_PATTERN}' disappeared; start ${R_BASE_EXIT_GRACE_SEC}s grace"
        elif (( now_ts - r_base_gone_ts >= R_BASE_EXIT_GRACE_SEC )); then
          echo "[wait] wrapper still alive after ${R_BASE_EXIT_GRACE_SEC}s; forcing workload teardown"
          terminate_workload_cgroup "pattern '${R_BASE_EXIT_PATTERN}' disappeared"
          break
        fi
      fi
    fi

    sleep 1
  done

  set +e
  wait "$WORKLOAD_PID" 2>/dev/null
  wait_rc=$?
  set -e

  WORKLOAD_WAIT_RC="$wait_rc"
}

reclaim_loop() {
  local low_kb=$((LOCAL_FREE_LOW_MB * 1024))
  local reclaim_log="${RUN_OUT_DIR}/reclaim_loop.log"
  local demotion_disabled="0"
  local r_base_seen="0"

  : > "$reclaim_log"
  echo "[reclaim] start: DST_NODE=$DST_NODE low=${LOCAL_FREE_LOW_MB}MB amount=${RECLAIM_AMOUNT_MB}MB cpu=$MIGRATION_CPU" >> "$reclaim_log"
  echo "[reclaim] demotion disable condition: once pattern '${R_BASE_EXIT_PATTERN}' has appeared in cgroup ${CGROUP_NAME} and then disappears => disable demotion_enabled only" >> "$reclaim_log"
  echo "[reclaim] init used: node${STOP_NODE0}=${INIT_USED_NODE0_KB:-NA}kB node${STOP_NODE1}=${INIT_USED_NODE1_KB:-NA}kB" >> "$reclaim_log"

  while true; do
    if ! pid_is_running_non_zombie "${WORKLOAD_PID:-}"; then
      echo "[reclaim] workload exited; stop loop" >> "$reclaim_log"
      break
    fi

    local now_ts elapsed free_kb used0_kb used1_kb delta0_kb delta1_kb
    local r_base_pids r_base_pids_log r_base_present
    now_ts="$(date +%s)"
    elapsed=$(( now_ts - WORKLOAD_START_TS ))

    free_kb="$(node_memfree_kb "$DST_NODE" 2>/dev/null || echo "")"
    used0_kb="$(node_memused_kb "$STOP_NODE0" 2>/dev/null || echo "")"
    used1_kb="$(node_memused_kb "$STOP_NODE1" 2>/dev/null || echo "")"

    [[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=0

    delta0_kb="NA"
    delta1_kb="NA"
    if [[ "$used0_kb" =~ ^[0-9]+$ ]] && [[ "$INIT_USED_NODE0_KB" =~ ^[0-9]+$ ]]; then
      delta0_kb="$(abs_diff_kb "$used0_kb" "$INIT_USED_NODE0_KB")"
    fi
    if [[ "$used1_kb" =~ ^[0-9]+$ ]] && [[ "$INIT_USED_NODE1_KB" =~ ^[0-9]+$ ]]; then
      delta1_kb="$(abs_diff_kb "$used1_kb" "$INIT_USED_NODE1_KB")"
    fi

    r_base_pids="$(cgroup_pattern_pids "$R_BASE_EXIT_PATTERN" 2>/dev/null || true)"
    r_base_present="no"
    r_base_pids_log="-"
    if [[ -n "$r_base_pids" ]]; then
      r_base_seen="1"
      r_base_present="yes"
      r_base_pids_log="${r_base_pids//$'\n'/,}"
    fi

    echo "[reclaim] $(TZ=America/Chicago date '+%F %T') elapsed=${elapsed}s node${DST_NODE} MemFree=${free_kb}kB node${STOP_NODE0} MemUsed=${used0_kb:-NA}kB delta=${delta0_kb}kB node${STOP_NODE1} MemUsed=${used1_kb:-NA}kB delta=${delta1_kb}kB r_base_seen=${r_base_seen} r_base_present=${r_base_present} r_base_pids=${r_base_pids_log}" >> "$reclaim_log"

    if [[ "$DEMOTION_DISABLE_ON_RBASE_EXIT" == "1" ]] &&
       [[ "$demotion_disabled" == "0" ]] &&
       [[ "$r_base_seen" == "1" ]] &&
       [[ -z "$r_base_pids" ]]; then
      echo "[reclaim] demotion disable condition met after ${elapsed}s: pattern '${R_BASE_EXIT_PATTERN}' disappeared from cgroup ${CGROUP_NAME}" >> "$reclaim_log"

      echo "[reclaim] disabling demotion_enabled" >> "$reclaim_log"
      if ! runner_write_exact /sys/kernel/mm/numa/demotion_enabled 0 >> "$reclaim_log" 2>&1; then
        echo "[reclaim] ERROR: failed to disable demotion_enabled" >> "$reclaim_log"
        return 1
      fi
      echo "[reclaim] demotion_enabled now=$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo NA)" >> "$reclaim_log"

      demotion_disabled="1"
    fi

    if (( free_kb < low_kb )); then
      echo "[reclaim] threshold hit: ${free_kb}kB < ${low_kb}kB => reclaim ${RECLAIM_AMOUNT_MB}M" >> "$reclaim_log"
      if ! memcg_reclaim_once "$RECLAIM_AMOUNT_MB" >> "$reclaim_log" 2>&1; then
        echo "[reclaim] ERROR: memory.reclaim failed" >> "$reclaim_log"
        return 1
      fi
      echo "[reclaim] vmstat snapshot after reclaim" >> "$reclaim_log"
      grep -E 'pgdemote|pgpromote|pgmigrate' /proc/vmstat >> "$reclaim_log" 2>/dev/null || true
      sleep "$RECLAIM_COOLDOWN_SEC"
    else
      sleep "$RECLAIM_CHECK_SEC"
    fi
  done
}

migration_reclaim_disable_monitor() {
  local timeout_sec="${MIGRATION_RECLAIM_DISABLE_AFTER_SEC:-0}"
  local timeout_log="${RUN_OUT_DIR}/migration_reclaim_disable_monitor.log"
  local now_ts elapsed

  : > "$timeout_log"
  echo "[timeout] start: disable_after=${timeout_sec}s" >> "$timeout_log"

  if ! [[ "$timeout_sec" =~ ^[0-9]+$ ]] || (( timeout_sec <= 0 )); then
    echo "[timeout] disabled" >> "$timeout_log"
    return 0
  fi

  while true; do
    if ! pid_is_running_non_zombie "${WORKLOAD_PID:-}"; then
      echo "[timeout] workload exited; stop monitor" >> "$timeout_log"
      break
    fi

    now_ts="$(date +%s)"
    elapsed=$(( now_ts - WORKLOAD_START_TS ))

    if (( elapsed >= timeout_sec )); then
      echo "[timeout] elapsed=${elapsed}s >= ${timeout_sec}s; stop reclaim + migration_manager" >> "$timeout_log"

      if [[ -n "${RECLAIM_PID:-}" ]] && kill -0 "$RECLAIM_PID" 2>/dev/null; then
        echo "[timeout] stopping reclaim_loop pid=${RECLAIM_PID}" >> "$timeout_log"
        kill "$RECLAIM_PID" >> "$timeout_log" 2>&1 || true
      else
        echo "[timeout] reclaim_loop not running" >> "$timeout_log"
      fi

      if manager_is_active "${MIGRATION_PID:-}"; then
        echo "[timeout] stopping migration_manager pid=${MIGRATION_PID}" >> "$timeout_log"
        if ! manager_signal INT "$MIGRATION_PID" >> "$timeout_log" 2>&1 &&
           manager_is_active "${MIGRATION_PID:-}"; then
          echo "[timeout] ERROR: migration_manager remained active after signal failure" >> "$timeout_log"
          return 1
        fi
      else
        echo "[timeout] migration_manager not running" >> "$timeout_log"
      fi
      if ! bash "${SET_PARA_DIR}/tracker.sh" disable >> "$timeout_log" 2>&1; then
        echo "[timeout] ERROR: failed to disable CHMU tracking" >> "$timeout_log"
        return 1
      fi

      break
    fi

    sleep 1
  done
}

apply_mode_demotion_policy() {
  case "$mode" in
    baseline)
      echo "[demotion] baseline => set demotion_enabled=0"
      runner_write_exact /sys/kernel/mm/numa/demotion_enabled 0
      ;;
    mig|anb|damon)
      echo "[demotion] $mode => set demotion_enabled=1"
      runner_write_exact /sys/kernel/mm/numa/demotion_enabled 1
      ;;
  esac

  echo "[demotion] current=$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo NA)"
}

echo "==== Setup cgroup (v2) under /sys/fs/cgroup ===="
echo "[cgroup] path=$CGROUP_PATH"

if [[ -f "${CGROUP_ROOT}/cgroup.controllers" && -f "${CGROUP_ROOT}/cgroup.subtree_control" ]]; then
  ctrls="$(cat "${CGROUP_ROOT}/cgroup.controllers" || true)"
  if echo "$ctrls" | grep -qw cpuset; then echo "+cpuset" | $SUDO tee "${CGROUP_ROOT}/cgroup.subtree_control" >/dev/null 2>&1 || true; fi
  if echo "$ctrls" | grep -qw memory; then echo "+memory" | $SUDO tee "${CGROUP_ROOT}/cgroup.subtree_control" >/dev/null 2>&1 || true; fi
fi

$SUDO mkdir -p "$CGROUP_PATH"
runner_assert_cgroup_empty
$SUDO chown root:root "$CGROUP_PATH" "${CGROUP_PATH}/cgroup.procs"
$SUDO chmod 0755 "$CGROUP_PATH"
$SUDO chmod 0644 "${CGROUP_PATH}/cgroup.procs"

cg_write "$WL_CPUS" "${CGROUP_PATH}/cpuset.cpus"
if [[ "$mode" == "baseline" ]]; then
  cg_write "$BASELINE_START_MEMS" "${CGROUP_PATH}/cpuset.mems"
else
  cg_write "$SRC_NODE" "${CGROUP_PATH}/cpuset.mems"
fi

echo "[cgroup] cpuset.cpus=$(cat "${CGROUP_PATH}/cpuset.cpus")"
echo "[cgroup] cpuset.mems=$(cat "${CGROUP_PATH}/cpuset.mems")"
[[ -f "${CGROUP_PATH}/cpuset.mems.effective" ]] && echo "[cgroup] mems.effective=$(cat "${CGROUP_PATH}/cpuset.mems.effective")"
echo

# capture initial node usage BEFORE workload starts
INIT_USED_NODE0_KB="$(node_memused_kb "$STOP_NODE0" 2>/dev/null || echo "")"
INIT_USED_NODE1_KB="$(node_memused_kb "$STOP_NODE1" 2>/dev/null || echo "")"
echo "==== Initial node usage baseline ===="
echo "[baseline_mem] node${STOP_NODE0} MemUsed=${INIT_USED_NODE0_KB:-NA}kB"
echo "[baseline_mem] node${STOP_NODE1} MemUsed=${INIT_USED_NODE1_KB:-NA}kB"
echo

echo "==== Apply mode-specific demotion policy ===="
apply_mode_demotion_policy
echo

echo "[1/4] Set CHMU params + reset"
pushd "$SET_PARA_DIR" >/dev/null
bash ./prepare_benchmark.sh "$mode" "$cnt_th"
popd >/dev/null
echo

DBG_LOG="${RUN_OUT_DIR}/debug_monitor.log"
rotate_if_exists "$DBG_LOG"

debug_monitor() {
  local pid="$1"
  while true; do
    echo "" >> "$DBG_LOG"
    echo "===== [debug] periodic @ $(TZ=America/Chicago date '+%F %T') =====" >> "$DBG_LOG"
    echo "[debug] mode=$mode benchmark=$benchmark db=$graph_db omp_threads=$OMP_THREADS" >> "$DBG_LOG"
    echo "[debug] cpuset.cpus=$(cat "$CGROUP_PATH/cpuset.cpus" 2>/dev/null || echo NA)" >> "$DBG_LOG"
    echo "[debug] cpuset.mems=$(cat "$CGROUP_PATH/cpuset.mems" 2>/dev/null || echo NA)" >> "$DBG_LOG"
    echo "[debug] mems.effective=$(cat "$CGROUP_PATH/cpuset.mems.effective" 2>/dev/null || echo NA)" >> "$DBG_LOG"

    echo "--- /proc/vmstat ---" >> "$DBG_LOG"
    grep -E "pages|pg" /proc/vmstat >> "$DBG_LOG" 2>/dev/null || true

    if ! pid_is_running_non_zombie "$pid"; then
      echo "===== [debug] workload exited, stop monitor @ $(TZ=America/Chicago date '+%F %T') =====" >> "$DBG_LOG"
      break
    fi

    echo "--- /proc/$pid/status ---" >> "$DBG_LOG"
    egrep "Name|State|PPid|VmRSS|VmSize|Cpus_allowed_list|Mems_allowed_list" "/proc/$pid/status" >> "$DBG_LOG" 2>/dev/null || true

    if command -v numastat >/dev/null 2>&1; then
      echo "--- numastat -c ${benchmark} ---" >> "$DBG_LOG"
      numastat -c "$benchmark" >> "$DBG_LOG" 2>/dev/null || true
    fi

    sleep "$DBG_INTERVAL_SEC"
  done
}

echo "[2/4] Start GAPBS workload INSIDE cgroup (fail-fast join verification)"
WORKLOAD_LOG="${RUN_OUT_DIR}/${benchmark}_${graph_db}.log"
rotate_if_exists "$WORKLOAD_LOG"

(
  set -euo pipefail
  local_pid="${BASHPID:-$$}"
  kill -STOP "$local_pid"

  if command -v taskset >/dev/null 2>&1; then
    taskset -pc "$WL_CPUS" "$local_pid" >/dev/null 2>&1 || true
  fi

  if ! grep -Fxq "0::/${CGROUP_NAME}" "/proc/${local_pid}/cgroup"; then
    echo "[ERR] join failed"
    cat "/proc/${local_pid}/cgroup"
    exit 98
  fi

  export OMP_NUM_THREADS="$OMP_THREADS"
  cd "$GAPBS_DIR"

  if [[ "$mode" == "baseline" ]]; then
    echo "[baseline] launch policy=${BASELINE_MEM_POLICY} start_mems=${BASELINE_START_MEMS} final_mems=${BASELINE_MEMS}"
    case "$BASELINE_MEM_POLICY" in
      interleave)
        command -v numactl >/dev/null 2>&1 || { echo "ERROR: numactl not found for BASELINE_MEM_POLICY=interleave"; exit 97; }
        exec numactl --interleave="${BASELINE_MEMS}" "${GAPBS_CMD[@]}"
        ;;
      membind)
        command -v numactl >/dev/null 2>&1 || { echo "ERROR: numactl not found for BASELINE_MEM_POLICY=membind"; exit 97; }
        exec numactl --membind="${BASELINE_MEMS}" "${GAPBS_CMD[@]}"
        ;;
    esac
    exec "${GAPBS_CMD[@]}"
  fi

  exec "${GAPBS_CMD[@]}"
) > "$WORKLOAD_LOG" 2>&1 &

WORKLOAD_PID=$!
runner_attach_stopped_pid_to_cgroup "$WORKLOAD_PID" || exit 1
WORKLOAD_START_TS="$(date +%s)"
echo "Workload PID: $WORKLOAD_PID"
echo "Workload log: $WORKLOAD_LOG"
echo "WORKLOAD_START_TS=$WORKLOAD_START_TS"

if [[ "$ENABLE_DEBUG_MONITOR" == "1" ]]; then
  debug_monitor "$WORKLOAD_PID" &
  MON_PID=$!
  echo "debug_monitor PID: $MON_PID log: $DBG_LOG"

  if command -v taskset >/dev/null 2>&1; then
    taskset -pc "$MIGRATION_CPU" "$MON_PID" >/dev/null 2>&1 || true
  fi
else
  echo "debug_monitor: disabled"
fi

startup_delay_sec="2"
if [[ "$mode" == "baseline" ]]; then
  startup_delay_sec="$BASELINE_EXPAND_DELAY_SEC"
fi
sleep "$startup_delay_sec"
if ! pid_is_running_non_zombie "$WORKLOAD_PID"; then
  echo "ERROR: workload died immediately. Tail of workload log:"
  tail -n 120 "$WORKLOAD_LOG" || true
  exit 1
fi
echo

case "$mode" in
  baseline)
    echo "[baseline] keep/expand cpuset.mems allowing: ${BASELINE_MEMS} (start=${BASELINE_START_MEMS} policy=${BASELINE_MEM_POLICY})"
    cg_write "${BASELINE_MEMS}" "${CGROUP_PATH}/cpuset.mems"
    echo "[cgroup] cpuset.mems now=$(cat "${CGROUP_PATH}/cpuset.mems")"
    ;;

  mig)
    echo "[mig] expand cpuset.mems to allow DST for migration"
    cg_write "${SRC_NODE},${DST_NODE}" "${CGROUP_PATH}/cpuset.mems"
    echo "[cgroup] cpuset.mems now=$(cat "${CGROUP_PATH}/cpuset.mems")"
    [[ -f "${CGROUP_PATH}/cpuset.mems.effective" ]] && echo "[cgroup] mems.effective now=$(cat "${CGROUP_PATH}/cpuset.mems.effective")"

    echo "[mig] start migration_manager"
    MIGRATION_LOG="${RUN_OUT_DIR}/migration_manager.log"
    FEATURE_TRACE_PATH="${CHMU_RUNTIME_DIR}/ml_feature_trace.csv"
    rotate_if_exists "$MIGRATION_LOG"
    pushd "$MIGRATION_MANAGER_DIR" >/dev/null
    manager_env=(
      env
      "CHMU_MODEL_PATH=${CHMU_MODEL_PATH:-}"
      "CHMU_PERF_BIN=${CHMU_PERF_BIN}"
      "CHMU_READY_FILE=${MIGRATION_READY_FILE}"
      "CHMU_START_FILE=${MIGRATION_START_FILE}"
      "CHMU_START_GATE_TIMEOUT_SEC=${MIGRATION_START_GATE_TIMEOUT_SEC}"
      "CHMU_RUNTIME_DIR=${CHMU_RUNTIME_DIR}"
      "CHMU_ALLOW_PREDICTOR_FALLBACK=${CHMU_ALLOW_PREDICTOR_FALLBACK}"
    )
    if [[ "$CHMU_ENABLE_FEATURE_TRACE" == "1" ]]; then
      manager_env+=("CHMU_FEATURE_TRACE_PATH=${FEATURE_TRACE_PATH}")
    else
      manager_env+=("CHMU_FEATURE_TRACE_PATH=")
    fi
    manager_command=(
      taskset -c "$MIGRATION_CPU" ./migration_manager
      -s "$poll_ms" -P "$WORKLOAD_PID" -X "$MIGRATION_MAX_MIGRATED_PFNS"
      -A "$epoch_cycle_a" -B "$epoch_cycle_b" -E "$MIGRATION_PREDICTOR_INTERVAL_MS"
    )
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      "${manager_env[@]}" "${manager_command[@]}" > "$MIGRATION_LOG" 2>&1 &
    else
      sudo "${manager_env[@]}" "${manager_command[@]}" > "$MIGRATION_LOG" 2>&1 &
    fi
    MIGRATION_JOB_PID=$!
    popd >/dev/null
    manager_wait_for_ready || exit 1
    bash "${SET_PARA_DIR}/start_tracking.sh" "$epoch_cycle_a"
    printf '%s\n' "$MIGRATION_PID" > "$MIGRATION_START_FILE"
    echo "migration_manager PID: $MIGRATION_PID (launcher PID: $MIGRATION_JOB_PID)"
    echo "migration_manager log: $MIGRATION_LOG"
    echo "migration_manager model path: ${CHMU_MODEL_PATH:-<builtin>}"
    if [[ "$CHMU_ENABLE_FEATURE_TRACE" == "1" ]]; then
      echo "migration_manager feature trace archive: ${MANAGER_RUNTIME_ARCHIVE}/ml_feature_trace.csv"
    else
      echo "migration_manager feature trace: disabled"
    fi
    echo "migration_manager predictor interval: ${MIGRATION_PREDICTOR_INTERVAL_MS}ms"


    if [[ "$RECLAIM_LOOP_ENABLE" == "1" ]]; then
      echo "[mig] start reclaim_loop"
      runner_checked_background reclaim_loop reclaim_loop &
      RECLAIM_PID=$!
      echo "reclaim_loop PID: $RECLAIM_PID"
      echo "reclaim_loop log: ${RUN_OUT_DIR}/reclaim_loop.log"

      if command -v taskset >/dev/null 2>&1; then
        taskset -pc "$MIGRATION_CPU" "$RECLAIM_PID" >/dev/null
      fi
    fi

    echo "[mig] start migration/reclaim timeout monitor"
    runner_checked_background migration_reclaim_disable_monitor migration_reclaim_disable_monitor &
    MIG_DISABLE_MON_PID=$!
    echo "migration/reclaim timeout monitor PID: $MIG_DISABLE_MON_PID"
    echo "migration/reclaim timeout log: ${RUN_OUT_DIR}/migration_reclaim_disable_monitor.log"
    ;;

  anb)
    echo "[anb] expand cpuset.mems to allow local(=${DST_NODE}) + cxl(=${SRC_NODE})"
    cg_write "${DST_NODE},${SRC_NODE}" "${CGROUP_PATH}/cpuset.mems"
    echo "[cgroup] cpuset.mems now=$(cat "${CGROUP_PATH}/cpuset.mems")"
    [[ -f "${CGROUP_PATH}/cpuset.mems.effective" ]] && echo "[cgroup] mems.effective now=$(cat "${CGROUP_PATH}/cpuset.mems.effective")"

    echo "[anb] enable Auto NUMA Balancing: /proc/sys/kernel/numa_balancing=${ANB_VALUE}"
    runner_write_exact /proc/sys/kernel/numa_balancing "$ANB_VALUE"
    ;;

  damon)
    echo "[damon] expand cpuset.mems to allow local(=${DST_NODE}) + cxl(=${SRC_NODE})"
    cg_write "${DST_NODE},${SRC_NODE}" "${CGROUP_PATH}/cpuset.mems"
    echo "[cgroup] cpuset.mems now=$(cat "${CGROUP_PATH}/cpuset.mems")"
    [[ -f "${CGROUP_PATH}/cpuset.mems.effective" ]] && echo "[cgroup] mems.effective now=$(cat "${CGROUP_PATH}/cpuset.mems.effective")"

    if [[ "$DAMON_ALSO_ENABLE_ANB" == "1" ]]; then
      echo "[damon] (optional) also enable ANB: /proc/sys/kernel/numa_balancing=${ANB_VALUE}"
      runner_write_exact /proc/sys/kernel/numa_balancing "$ANB_VALUE"
    else
      echo "[damon] keep numa_balancing as-is (recommended: 0 to avoid mixing effects)"
    fi

    echo "==== [damon] start DAMO ===="
    echo "[damon] cmd: $DAMO_BIN stop"
    $SUDO "$DAMO_BIN" stop 2>&1 || true
    [[ -f "$DAMO_CONFIG" ]] || { echo "ERROR: DAMO_CONFIG not found: $DAMO_CONFIG"; exit 1; }
    echo "[damon] cmd: $DAMO_BIN start $DAMO_CONFIG"
    $SUDO "$DAMO_BIN" start "$DAMO_CONFIG" 2>&1
    DAMON_STARTED="1"

    echo "==== [damon] damo report (after start) ===="
    $SUDO "$DAMO_BIN" report "$DAMO_REPORT_KIND" 2>&1 || true
    ;;
esac

echo

echo "[4/4] Waiting workload..."
wait_for_workload_exit
work_rc="$WORKLOAD_WAIT_RC"
echo "Workload finished rc=$work_rc"

if [[ -n "${RECLAIM_PID:-}" ]] && kill -0 "$RECLAIM_PID" 2>/dev/null; then
  kill "$RECLAIM_PID" 2>/dev/null || true
  wait "$RECLAIM_PID" 2>/dev/null || true
fi

if [[ -n "${MIG_DISABLE_MON_PID:-}" ]] && kill -0 "$MIG_DISABLE_MON_PID" 2>/dev/null; then
  kill "$MIG_DISABLE_MON_PID" 2>/dev/null || true
  wait "$MIG_DISABLE_MON_PID" 2>/dev/null || true
fi

if [[ -s "$BACKGROUND_ERROR_FILE" ]]; then
  BACKGROUND_FAILED=1
fi

manager_rc=0
if [[ "$mode" == "mig" ]]; then
  if manager_stop "workload completed"; then
    manager_rc=0
  else
    manager_rc=$?
  fi
fi

if bash "${SET_PARA_DIR}/tracker.sh" disable; then
  echo "[tracker] CHMU tracking disabled and verified"
else
  TRACKER_DISABLE_FAILED="1"
  echo "ERROR: failed to disable CHMU tracking after the workload" >&2
fi

summary="${RUN_OUT_DIR}/runtime_summary.txt"
{
  echo "mode=$mode benchmark=$benchmark db=$graph_db"
  echo "GAPBS_BIN=$GAPBS_BIN"
  echo "GAPBS_GRAPH_PATH=$GAPBS_GRAPH_PATH"
  echo "OMP_THREADS=$OMP_THREADS"
  echo "WORKLOAD_PID=$WORKLOAD_PID rc=$work_rc"
  echo "MIGRATION_MANAGER_PID=${MIGRATION_PID:-NA} rc=${manager_rc} failed=${MANAGER_FAILED}"
  echo "BACKGROUND_CONTROL_FAILED=${BACKGROUND_FAILED}"
  echo "TRACKER_DISABLE_FAILED=${TRACKER_DISABLE_FAILED}"
  echo "WORKLOAD_START_TS=$WORKLOAD_START_TS"
  echo "BASELINE_START_MEMS=$BASELINE_START_MEMS"
  echo "BASELINE_MEMS=$BASELINE_MEMS"
  echo "BASELINE_MEM_POLICY=$BASELINE_MEM_POLICY"
  echo "BASELINE_EXPAND_DELAY_SEC=$BASELINE_EXPAND_DELAY_SEC"
  echo "INIT_USED_NODE0_KB=$INIT_USED_NODE0_KB"
  echo "INIT_USED_NODE1_KB=$INIT_USED_NODE1_KB"
  echo "logs: $LOG_FILE $WORKLOAD_LOG"
  [[ -f "${RUN_OUT_DIR}/migration_manager.log" ]] && echo "migration log: ${RUN_OUT_DIR}/migration_manager.log"
  [[ -f "${RUN_OUT_DIR}/migration_reclaim_disable_monitor.log" ]] && echo "migration/reclaim timeout log: ${RUN_OUT_DIR}/migration_reclaim_disable_monitor.log"
  [[ -f "${RUN_OUT_DIR}/reclaim_loop.log" ]] && echo "reclaim log: ${RUN_OUT_DIR}/reclaim_loop.log"
  [[ -f "$DBG_LOG" ]] && echo "debug: $DBG_LOG"
} | tee "$summary"

echo "Saved: $summary"

final_rc="$work_rc"
if [[ "$MANAGER_FAILED" != 0 || "$manager_rc" != 0 || "$BACKGROUND_FAILED" != 0 || "$TRACKER_DISABLE_FAILED" != 0 ]]; then
  final_rc=1
fi
if [[ "$work_rc" != 0 ]]; then
  echo "ERROR: GAPBS workload failed with rc=${work_rc}" >&2
fi
if [[ "$MANAGER_FAILED" != 0 || "$manager_rc" != 0 ]]; then
  echo "ERROR: migration_manager failed with rc=${manager_rc}" >&2
fi
if [[ "$BACKGROUND_FAILED" != 0 ]]; then
  echo "ERROR: a background benchmark control failed; see ${BACKGROUND_ERROR_FILE}" >&2
fi
if [[ "$TRACKER_DISABLE_FAILED" != 0 ]]; then
  echo "ERROR: CHMU tracking could not be disabled cleanly" >&2
fi
exit "$final_rc"

#!/usr/bin/env bash

runner_normalize_kernel_bool() {
  case "${1,,}" in
    1|y|yes|true|on)  printf '1\n' ;;
    0|n|no|false|off) printf '0\n' ;;
    *) return 1 ;;
  esac
}

runner_values_equal() {
  local file="$1"
  local expected="$2"
  local actual="$3"
  local expected_normalized
  local actual_normalized

  if [[ "$file" == */numa/demotion_enabled ]]; then
    expected_normalized="$(runner_normalize_kernel_bool "$expected")" || return 1
    actual_normalized="$(runner_normalize_kernel_bool "$actual")" || return 1
    [[ "$actual_normalized" == "$expected_normalized" ]]
  else
    [[ "$actual" == "$expected" ]]
  fi
}

runner_write_exact() {
  local file="$1"
  local value="$2"
  local actual

  [[ -e "$file" ]] || {
    echo "ERROR: required control file is missing: $file" >&2
    return 1
  }
  printf '%s\n' "$value" | manager_run_root tee "$file" >/dev/null
  actual="$(< "$file")"
  runner_values_equal "$file" "$value" "$actual" || {
    echo "ERROR: $file readback '$actual' does not match '$value'" >&2
    return 1
  }
}

runner_set_thp_never() {
  local file="$1"
  local actual

  [[ -e "$file" ]] || {
    echo "ERROR: required THP control is missing: $file" >&2
    return 1
  }
  printf 'never\n' | manager_run_root tee "$file" >/dev/null
  actual="$(< "$file")"
  [[ "$actual" == *'[never]'* ]] || {
    echo "ERROR: $file did not select never: $actual" >&2
    return 1
  }
}

runner_checked_background() {
  local label="$1"
  local rc=0
  shift

  set +e
  "$@"
  rc=$?
  set -e
  if (( rc != 0 && rc != 130 && rc != 143 )); then
    printf '%s rc=%d\n' "$label" "$rc" >> "$BACKGROUND_ERROR_FILE"
  fi
  return "$rc"
}

runner_sudo_keepalive() {
  while sudo -n -v >/dev/null 2>&1; do
    sleep 45
  done
  return 1
}

runner_attach_stopped_pid_to_cgroup() {
  local pid="$1"
  local state=""
  local attempt

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: invalid workload PID for cgroup attachment: $pid" >&2
    return 1
  }

  for (( attempt=0; attempt<100; attempt++ )); do
    if [[ ! -r "/proc/${pid}/status" ]]; then
      echo "ERROR: workload PID ${pid} exited before its cgroup stop gate" >&2
      return 1
    fi
    state="$(awk '/^State:/ { print $2; exit }' "/proc/${pid}/status")"
    case "$state" in
      T|t) break ;;
      Z|X|x)
        echo "ERROR: workload PID ${pid} entered state ${state} before cgroup attachment" >&2
        return 1
        ;;
    esac
    sleep 0.05
  done

  if [[ "$state" != T && "$state" != t ]]; then
    echo "ERROR: workload PID ${pid} did not reach its cgroup stop gate" >&2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi

  if ! printf '%s\n' "$pid" | manager_run_root tee "${CGROUP_PATH}/cgroup.procs" >/dev/null; then
    echo "ERROR: root could not attach workload PID ${pid} to ${CGROUP_PATH}" >&2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi

  if ! grep -Fqx "0::/${CGROUP_NAME}" "/proc/${pid}/cgroup"; then
    echo "ERROR: workload PID ${pid} is not in /${CGROUP_NAME} after root attachment" >&2
    cat "/proc/${pid}/cgroup" >&2 || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi

  if ! kill -CONT "$pid"; then
    echo "ERROR: could not release workload PID ${pid} from its cgroup stop gate" >&2
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  echo "[cgroup] attached workload PID ${pid} to /${CGROUP_NAME} as root; workload UID is unchanged"
}

runner_assert_cgroup_empty() {
  local stale_pids

  if ! manager_run_root test -e "${CGROUP_PATH}/cgroup.procs"; then
    return 0
  fi
  stale_pids="$(manager_run_root cat "${CGROUP_PATH}/cgroup.procs")" || return 1
  if [[ -n "$stale_pids" ]]; then
    echo "ERROR: ${CGROUP_PATH} still contains processes from an earlier run:" >&2
    echo "$stale_pids" >&2
    echo "Clean up those processes before retrying; this runner will not move or kill them automatically." >&2
    return 1
  fi
  if manager_run_root test -e "${CGROUP_PATH}/cgroup.events" &&
     manager_run_root grep -Fxq 'populated 1' "${CGROUP_PATH}/cgroup.events"; then
    echo "ERROR: ${CGROUP_PATH} has populated descendant cgroups from an earlier run." >&2
    echo "Clean up that cgroup subtree before retrying; this runner will not kill unknown tasks." >&2
    return 1
  fi
}

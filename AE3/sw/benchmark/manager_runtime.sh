#!/usr/bin/env bash

# Shared lifecycle helpers for the privileged migration_manager process.
# The sourcing runner provides SUDO, MIGRATION_MANAGER_DIR, MIGRATION_LOG,
# MIGRATION_READY_FILE, and the MIGRATION_* PID/status variables.

manager_run_root() {
  if [[ -n "${SUDO:-}" ]]; then
    $SUDO "$@"
  else
    "$@"
  fi
}

manager_run_artifact_user() {
  local current_uid
  local artifact_uid

  current_uid="$(id -u)"
  artifact_uid="$(id -u "${ARTIFACT_RUN_USER}")" || return 1
  if [[ "$current_uid" == "$artifact_uid" ]]; then
    "$@"
  elif [[ -n "${SUDO:-}" ]]; then
    $SUDO -u "${ARTIFACT_RUN_USER}" -- "$@"
  else
    sudo -n -u "${ARTIFACT_RUN_USER}" -- "$@"
  fi
}

manager_pid_is_running() {
  local pid="${1:-}"
  local stat_line
  local stat_tail
  local state
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  manager_run_root kill -0 "$pid" 2>/dev/null || return 1
  stat_line="$(manager_run_root cat "/proc/${pid}/stat" 2>/dev/null)" || return 1
  stat_tail="${stat_line##*) }"
  state="${stat_tail%% *}"
  [[ "$state" != Z && "$state" != X ]]
}

manager_identity_matches() {
  local pid="${1:-}"
  local expected_exe
  local actual_exe

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  expected_exe="$(readlink -f -- "${MIGRATION_MANAGER_DIR}/migration_manager")" || return 1
  actual_exe="$(manager_run_root readlink -f -- "/proc/${pid}/exe" 2>/dev/null)" || return 1
  [[ "$actual_exe" == "$expected_exe" ]]
}

manager_is_active() {
  local pid="${1:-}"
  manager_pid_is_running "$pid" && manager_identity_matches "$pid"
}

manager_remove_ready_file() {
  if [[ -n "${MIGRATION_READY_FILE:-}" ]]; then
    manager_run_root rm -f -- "$MIGRATION_READY_FILE" >/dev/null 2>&1 || true
  fi
  if [[ -n "${MIGRATION_START_FILE:-}" ]]; then
    manager_run_root rm -f -- "$MIGRATION_START_FILE" >/dev/null 2>&1 || true
  fi
}

manager_finalize_runtime() {
  local runtime_dir="${CHMU_RUNTIME_DIR:-}"
  local archive_dir="${MANAGER_RUNTIME_ARCHIVE:-}"

  [[ "$runtime_dir" == /run/micro_2026_arc_manager.* ]] || return 0
  if manager_run_root test -d "$runtime_dir"; then
    if [[ -n "$archive_dir" && -d "$archive_dir" ]]; then
      if manager_run_root chown -R -P \
           "${ARTIFACT_RUN_USER}:${ARTIFACT_RUN_GROUP}" "$runtime_dir" &&
         manager_run_artifact_user cp -a -- "${runtime_dir}/." "${archive_dir}/" &&
         manager_run_artifact_user chmod 700 "$archive_dir"; then
        :
      else
        echo "WARNING: could not archive manager runtime files from ${runtime_dir}" >&2
      fi
    fi
    manager_run_root rm -rf -- "$runtime_dir" >/dev/null 2>&1 || true
  fi
}

manager_terminate_job_fallback() {
  local job_pid="${MIGRATION_JOB_PID:-}"
  local signal_name
  local wait_rc=1

  if [[ "$job_pid" =~ ^[1-9][0-9]*$ ]]; then
    for signal_name in INT TERM KILL; do
      manager_run_root pkill "-${signal_name}" -P "$job_pid" >/dev/null 2>&1 || true
      manager_run_root kill "-${signal_name}" "$job_pid" >/dev/null 2>&1 || true
      sleep 1
      manager_pid_is_running "$job_pid" || break
    done

    set +e
    wait "$job_pid" 2>/dev/null
    wait_rc=$?
    set -e
  fi

  manager_remove_ready_file
  manager_finalize_runtime
  MIGRATION_EXIT_COLLECTED=1
  MIGRATION_EXIT_RC="$wait_rc"
  return 1
}

manager_wait_for_ready() {
  local timeout_sec="${MIGRATION_START_TIMEOUT_SEC:-10}"
  local candidate_pid=""
  local attempt
  local max_attempts
  local wait_rc

  [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: MIGRATION_START_TIMEOUT_SEC must be a positive integer" >&2
    return 1
  }
  max_attempts=$((timeout_sec * 10))

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if [[ -s "${MIGRATION_READY_FILE}" ]]; then
      IFS= read -r candidate_pid < "${MIGRATION_READY_FILE}" || true
      if [[ "$candidate_pid" =~ ^[1-9][0-9]*$ ]] &&
         manager_is_active "$candidate_pid"; then
        MIGRATION_PID="$candidate_pid"
        return 0
      fi
      if [[ "$candidate_pid" =~ ^[1-9][0-9]*$ ]] &&
         manager_pid_is_running "$candidate_pid"; then
        echo "ERROR: readiness PID ${candidate_pid} is not the expected migration_manager" >&2
        manager_terminate_job_fallback || true
        return 1
      fi
    fi

    if ! manager_pid_is_running "${MIGRATION_JOB_PID:-}"; then
      set +e
      wait "${MIGRATION_JOB_PID}" 2>/dev/null
      wait_rc=$?
      set -e
      MIGRATION_EXIT_COLLECTED=1
      MIGRATION_EXIT_RC="$wait_rc"
      manager_remove_ready_file
      manager_finalize_runtime
      echo "ERROR: migration_manager exited before readiness (rc=${wait_rc})" >&2
      [[ -r "${MIGRATION_LOG:-}" ]] && tail -n 120 "${MIGRATION_LOG}" >&2
      return 1
    fi
    sleep 0.1
  done

  echo "ERROR: migration_manager did not become ready within ${timeout_sec}s" >&2
  [[ -r "${MIGRATION_LOG:-}" ]] && tail -n 120 "${MIGRATION_LOG}" >&2
  manager_terminate_job_fallback || true
  return 1
}

manager_signal() {
  local signal_name="$1"
  local pid="${2:-${MIGRATION_PID:-}}"

  if manager_is_active "$pid"; then
    manager_run_root kill "-${signal_name}" "$pid"
    return
  fi
  if manager_pid_is_running "$pid"; then
    echo "ERROR: refusing to signal PID ${pid}: executable identity mismatch" >&2
    return 1
  fi
  return 1
}

manager_collect_exit() {
  local wait_rc

  if [[ "${MIGRATION_EXIT_COLLECTED:-0}" == 1 ]]; then
    return 0
  fi
  [[ "${MIGRATION_JOB_PID:-}" =~ ^[1-9][0-9]*$ ]] || return 1
  manager_is_active "${MIGRATION_PID:-}" && return 1
  if manager_pid_is_running "${MIGRATION_PID:-}"; then
    echo "ERROR: migration manager PID identity changed before collection" >&2
    MIGRATION_EXIT_RC=1
    return 2
  fi

  set +e
  wait "$MIGRATION_JOB_PID" 2>/dev/null
  wait_rc=$?
  set -e
  MIGRATION_EXIT_COLLECTED=1
  MIGRATION_EXIT_RC="$wait_rc"
  manager_remove_ready_file
  manager_finalize_runtime
  return 0
}

manager_stop() {
  local reason="${1:-runner cleanup}"
  local grace_sec="${MIGRATION_STOP_GRACE_SEC:-10}"
  local attempt
  local max_attempts
  local wait_rc

  if [[ "${MIGRATION_EXIT_COLLECTED:-0}" == 1 ]]; then
    manager_finalize_runtime
    return "${MIGRATION_EXIT_RC:-1}"
  fi
  [[ "$grace_sec" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: MIGRATION_STOP_GRACE_SEC must be a positive integer" >&2
    return 1
  }
  max_attempts=$((grace_sec * 10))

  if manager_is_active "${MIGRATION_PID:-}"; then
    echo "[manager] stopping PID ${MIGRATION_PID} (${reason})"
    manager_signal INT "$MIGRATION_PID" || true
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
      manager_is_active "$MIGRATION_PID" || break
      sleep 0.1
    done
    if manager_is_active "$MIGRATION_PID"; then
      echo "[manager] SIGINT grace expired; sending SIGTERM" >&2
      manager_signal TERM "$MIGRATION_PID" || true
      sleep 2
    fi
    if manager_is_active "$MIGRATION_PID"; then
      echo "[manager] SIGTERM grace expired; sending SIGKILL" >&2
      manager_run_root pkill -TERM -P "$MIGRATION_PID" >/dev/null 2>&1 || true
      sleep 1
      manager_run_root pkill -KILL -P "$MIGRATION_PID" >/dev/null 2>&1 || true
      manager_signal KILL "$MIGRATION_PID" || true
    fi
  elif manager_pid_is_running "${MIGRATION_PID:-}"; then
    echo "ERROR: manager PID identity mismatch during ${reason}" >&2
    manager_terminate_job_fallback || true
    return 1
  fi

  if [[ ! "${MIGRATION_PID:-}" =~ ^[1-9][0-9]*$ ]] &&
     manager_pid_is_running "${MIGRATION_JOB_PID:-}"; then
    echo "[manager] readiness was not established; terminating launcher (${reason})" >&2
    manager_terminate_job_fallback || true
    return 1
  fi

  if [[ "${MIGRATION_JOB_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
    set +e
    wait "$MIGRATION_JOB_PID" 2>/dev/null
    wait_rc=$?
    set -e
  else
    wait_rc=1
  fi
  MIGRATION_EXIT_COLLECTED=1
  MIGRATION_EXIT_RC="$wait_rc"
  manager_remove_ready_file
  manager_finalize_runtime
  return "$wait_rc"
}

#!/usr/bin/env bash
# compliance-checks.sh: Shared marketplace compliance check functions.
# Sourced by each vendor's validate.sh. Provides SSH helpers, compliance
# checks, and validation lifecycle functions used by both vendors.
#
# SSH handling: Uses a single SSH key (~/.ssh/id_ed25519) and multiplexing
# (ControlMaster) for all connections. Both vendors use the same CI build key,
# so no per-vendor SSH configuration is needed.

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_BASE_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY")

# Global: set to 1 if any compliance check fails. Validate scripts check this
# after run_compliance_checks() returns.
# shellcheck disable=SC2034
COMPLIANCE_FAIL=0

# --- SSH multiplexing ---

_ssh_socket_path() {
  local ip="$1"
  echo "/tmp/ssh-mux-$(echo "$ip" | tr -cd '0-9.')"
}

# Open a persistent SSH control socket for connection reuse.
_ssh_open() {
  local ip="$1"
  local socket
  socket=$(_ssh_socket_path "$ip")

  if ssh -O check -o ControlPath="$socket" "root@$ip" 2>/dev/null; then
    return 0
  fi

  ssh -fN \
    -o ControlMaster=yes \
    -o ControlPath="$socket" \
    -o ControlPersist=600 \
    "${SSH_BASE_OPTS[@]}" \
    "root@$ip" 2>/dev/null

  local i
  for i in $(seq 1 30); do
    if ssh -O check -o ControlPath="$socket" "root@$ip" 2>/dev/null; then
      return 0
    fi
    [ "$i" = "1" ] && echo "==> Establishing SSH connection to $ip..."
    sleep 1
  done

  echo "WARNING: SSH master connection to $ip failed to establish" >&2
  return 1
}

# Close the SSH control socket.
ssh_close() {
  local ip="$1"
  local socket
  socket=$(_ssh_socket_path "$ip")
  ssh -O exit -o ControlPath="$socket" "root@$ip" 2>/dev/null || true
  rm -f "$socket"
}

# Run a command on the remote VM via SSH. Prints only command output to stdout.
# Uses the multiplexed connection. Strips MOTD via markers and \r from CRLF.
# Args: $1 = IP, $2+ = command string
# shellcheck disable=SC2029
ssh_run() {
  local ip="$1"
  shift
  local marker="__SSH_RUN_RESULT__"
  local socket
  socket=$(_ssh_socket_path "$ip")

  _ssh_open "$ip" || return 1

  ssh -T -o ControlPath="$socket" "${SSH_BASE_OPTS[@]}" "root@$ip" \
    "echo $marker; $*; echo $marker" 2>/dev/null </dev/null \
    | tr -d '\r' \
    | sed -n "/^${marker}$/,/^${marker}$/p" \
    | sed "1d;\$d"
}

# Run a one-off SSH command (not multiplexed). For pre-check SSH readiness
# loops and health checks where multiplexing isn't needed yet.
# Args: $1 = IP, $2+ = command string
# shellcheck disable=SC2029
ssh_once() {
  local ip="$1"
  shift
  ssh -T "${SSH_BASE_OPTS[@]}" "root@$ip" "$@" 2>/dev/null </dev/null
}

# --- Remote helpers ---
# These run on the remote VM via ssh_run.

# Check if a command exists on the remote VM.
# Args: $1 = IP, $2 = command name
# Returns: 0 if exists, 1 if not
remote_cmd_exists() {
  local ip="$1"
  local cmd="$2"
  local path
  path=$(ssh_run "$ip" "command -v $cmd 2>/dev/null")
  [ -n "$path" ] && echo "$path"
}

# Run a remote command and return the result as a normalized integer.
# Fixes issues where grep -c returns "0\n0" (exit 1 + || echo 0).
# Args: $1 = IP, $2 = command string
# Returns: integer on stdout
_remote_int() {
  local ip="$1"
  shift
  local result
  result=$(ssh_run "$ip" "$*")
  result=$(printf '%s' "$result" | tr -cd '0-9')
  echo "${result:-0}"
}

# Emit a PASS/WARN/FAIL line based on an integer count.
# Args: $1 = count, $2 = pass message, $3 = warn/fail message, $4 = mode (warn|fail)
_count_result() {
  local count="$1"
  local pass_msg="$2"
  local fail_msg="$3"
  local mode="${4:-warn}"
  if [ "$count" = "0" ]; then
    echo "PASS: $pass_msg"
  else
    echo "$(tr '[:lower:]' '[:upper:]' <<< "$mode"): $fail_msg"
    [ "$mode" = "fail" ] && return 1
  fi
  return 0
}

# --- Checks ---

# Check: no SSH authorized_keys on root.
# On validation droplets, the cloud provider injects an SSH key on creation.
check_ssh_keys() {
  local ip="$1"
  local count
  count=$(_remote_int "$ip" "wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo 0")
  _count_result "$count" "no SSH authorized_keys" \
    "authorized_keys has $count entries (expected on validation droplet)" warn
}

# Check: root bash history cleared.
check_bash_history() {
  local ip="$1"
  local count
  count=$(_remote_int "$ip" "wc -l < /root/.bash_history 2>/dev/null || echo 0")
  _count_result "$count" "bash history cleared" \
    "bash history has $count lines" fail
}

# Check: firewall active (ufw or firewalld). Non-blocking WARN.
check_firewall() {
  local ip="$1"
  local status
  status=$(ssh_run "$ip" "ufw status 2>/dev/null | head -1 || systemctl is-active ufw 2>/dev/null || systemctl is-active firewalld 2>/dev/null || echo inactive")
  if echo "$status" | grep -qE "(^|[[:space:]])active($|[[:space:]])"; then
    echo "PASS: firewall active"
  else
    echo "WARN: firewall not active (non-blocking, matches DO img-check behavior)"
  fi
  return 0
}

# Check: cloud-init installed.
check_cloud_init() {
  local ip="$1"
  local path
  path=$(remote_cmd_exists "$ip" "cloud-init")
  if [ -n "$path" ]; then
    echo "PASS: cloud-init installed ($path)"
  else
    echo "FAIL: cloud-init not installed"
    return 1
  fi
  return 0
}

# Check: cloud-init completed successfully.
check_cloud_init_status() {
  local ip="$1"
  local status
  status=$(ssh_run "$ip" "cloud-init status 2>/dev/null | head -1")
  if echo "$status" | grep -qi "done"; then
    echo "PASS: cloud-init status: done"
  else
    echo "FAIL: cloud-init status: $status"
    return 1
  fi
  return 0
}

# Check: no pending security updates.
check_pending_updates() {
  local ip="$1"
  local count
  count=$(_remote_int "$ip" "apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true")
  _count_result "$count" "no pending updates" \
    "$count pending updates" warn
}

# Check: no large log files in /var/log.
check_logs_cleared() {
  local ip="$1"
  local count
  count=$(_remote_int "$ip" "find /var/log -type f -size +10M 2>/dev/null | wc -l")
  _count_result "$count" "no large log files" \
    "$count log files >10MB found in /var/log" warn
}

# --- Validation lifecycle ---

# Run a single check function and capture PASS/WARN/FAIL. Updates COMPLIANCE_FAIL.
# Args: $1 = label (unused, kept for readability at call site), $2+ = check function + args
# shellcheck disable=SC2034
_run_check() {
  local label="$1"
  shift
  local result
  result=$("$@" 2>&1) || true
  echo "  $result"
  if echo "$result" | grep -q "^FAIL"; then
    COMPLIANCE_FAIL=1
  fi
}

# Run the standard set of marketplace compliance checks.
# Args: $1 = IP address
run_compliance_checks() {
  local ip="$1"
  echo "==> Running marketplace compliance checks..."
  # shellcheck disable=SC2034
  COMPLIANCE_FAIL=0

  _run_check "ssh-keys"         check_ssh_keys         "$ip"
  _run_check "bash-history"     check_bash_history    "$ip"
  _run_check "firewall"         check_firewall        "$ip"
  _run_check "cloud-init"       check_cloud_init      "$ip"
  _run_check "cloud-init-status" check_cloud_init_status "$ip"
  _run_check "pending-updates"  check_pending_updates  "$ip"
  _run_check "logs"             check_logs_cleared    "$ip"
}

# Wait for SSH to become available on a freshly booted VM.
# Detects cloud-init SSH lockout ("Please wait" message).
# Args: $1 = IP, $2 = max attempts (default 30)
wait_for_ssh() {
  local ip="$1"
  local max="${2:-30}"
  local result
  echo "==> Waiting for SSH to become available..."
  for i in $(seq 1 "$max"); do
    result=$(ssh_once "$ip" "echo ready" 2>/dev/null) || true
    if [ "$result" = "ready" ]; then
      echo "==> SSH ready after $((i * 10)) seconds"
      return 0
    fi
    if echo "$result" | grep -q "Please wait"; then
      echo "    Attempt $i: SSH up but cloud-init still running, waiting 10s..."
    else
      echo "    Attempt $i: SSH not ready, waiting 10s..."
    fi
    sleep 10
  done
  echo "Error: SSH did not become available within $((max * 10)) seconds" >&2
  return 1
}

# Wait for cloud-init to reach "done" status.
# Args: $1 = IP, $2 = max attempts (default 12)
wait_for_cloud_init() {
  local ip="$1"
  local max="${2:-12}"
  local status
  echo "==> Waiting for cloud-init to settle..."
  for i in $(seq 1 "$max"); do
    status=$(ssh_once "$ip" "cloud-init status" 2>/dev/null || true)
    if echo "$status" | grep -qi "done"; then
      echo "==> cloud-init done after $((i * 10)) seconds"
      return 0
    fi
    echo "    cloud-init still running: $status"
    sleep 10
  done
  echo "Warning: cloud-init did not report done within $((max * 10)) seconds" >&2
  return 0
}

# Run health checks: s3-server service + Docker containers + HTTP healthz.
# Sets HEALTH_EXIT and HTTP_CODE globals.
# Args: $1 = IP address
run_health_checks() {
  local ip="$1"
  echo ""
  echo "==> Running health checks..."

  set +e
  ssh_once "$ip" \
    "systemctl is-active s3-server.service && docker ps --format '{{.Names}} {{.Status}}'"
  HEALTH_EXIT=$?
  set -e

  echo "==> Checking HTTP healthz endpoint..."
  set +e
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ip/_panel/healthz" 2>/dev/null || echo "000")
  set -e

  echo "==> Health check exit code: $HEALTH_EXIT"
  echo "==> HTTP healthz status code: $HTTP_CODE"
}

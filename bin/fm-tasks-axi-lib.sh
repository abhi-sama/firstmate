# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/fm-session-start.sh's backlog listing and once in the bin/fm-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in FM_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive a
#     tasks-axi upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
# Both layers are bounded by process lifetime, so a tasks-axi install or upgrade
# is picked up by the next process rather than being cached to disk.
#
# BINARY RESOLUTION. A primary firstmate session normally inherits tasks-axi on
# PATH from the nvm-initialised login shell it started from. A crew or scout
# shell spawned into a task worktree does not re-establish that PATH, so a
# bare `tasks-axi` invocation fails there even when a compatible install
# exists on the same machine. fm_tasks_axi_bin resolves the executable once
# per process into FM_TASKS_AXI_BIN, tried in this order: an inherited
# FM_TASKS_AXI_BIN override, PATH, the current nvm node version's bin, then the
# npm global prefix bin. Every probe below calls fm_tasks_axi_bin instead of
# invoking tasks-axi bare; bin/fm-decision-hold.sh does the same in its own
# tasks_axi() and require_tasks_axi() after sourcing this file, which is the
# chokepoint that previously left crew self-filed decision holds unreachable.

FM_TASKS_AXI_MIN=0.2.4

FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE
case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

FM_TASKS_AXI_BIN=${FM_TASKS_AXI_BIN:-}
FM_TASKS_AXI_BIN_RESOLVED=0

fm_tasks_axi_nvm_fallback() {
  local nvm_dir=${NVM_DIR:-$HOME/.nvm} dir base version major minor patch extra
  local best='' best_major=-1 best_minor=-1 best_patch=-1
  for dir in "$nvm_dir"/versions/node/*/bin; do
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -x "$dir/tasks-axi" ] || continue
    base=${dir%/bin}
    version=${base##*/}
    version=${version#v}
    IFS=. read -r major minor patch extra <<< "$version"
    case "$major:$minor:$patch:$extra" in *[!0-9:]*) continue ;; esac
    [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || continue
    if [ "$major" -gt "$best_major" ] ||
      { [ "$major" -eq "$best_major" ] && [ "$minor" -gt "$best_minor" ]; } ||
      { [ "$major" -eq "$best_major" ] && [ "$minor" -eq "$best_minor" ] && [ "$patch" -gt "$best_patch" ]; }; then
      best=$dir
      best_major=$major
      best_minor=$minor
      best_patch=$patch
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s/tasks-axi\n' "$best"
}

fm_tasks_axi_npm_global_fallback() {
  local prefix
  command -v npm >/dev/null 2>&1 || return 1
  prefix=$(npm prefix -g 2>/dev/null) || return 1
  [ -n "$prefix" ] || return 1
  if [ -x "$prefix/bin/tasks-axi" ]; then
    printf '%s/bin/tasks-axi\n' "$prefix"
  elif [ -x "$prefix/tasks-axi" ]; then
    printf '%s/tasks-axi\n' "$prefix"
  else
    return 1
  fi
}

# Resolves and memoises the tasks-axi binary for this process; prints the
# absolute path and returns 0, or returns 1 if nothing was found anywhere in
# the search order. A candidate only has to exist to be picked here: whether
# it is new enough stays the separate concern fm_tasks_axi_compatible_probe
# checks against whatever fm_tasks_axi_bin resolved.
fm_tasks_axi_bin() {
  local candidate
  if [ "$FM_TASKS_AXI_BIN_RESOLVED" != 1 ]; then
    candidate=$FM_TASKS_AXI_BIN
    [ -n "$candidate" ] && [ -x "$candidate" ] || candidate=$(command -v tasks-axi 2>/dev/null || true)
    [ -n "$candidate" ] || candidate=$(fm_tasks_axi_nvm_fallback 2>/dev/null || true)
    [ -n "$candidate" ] || candidate=$(fm_tasks_axi_npm_global_fallback 2>/dev/null || true)
    FM_TASKS_AXI_BIN=$candidate
    FM_TASKS_AXI_BIN_RESOLVED=1
  fi
  [ -n "$FM_TASKS_AXI_BIN" ] || return 1
  printf '%s\n' "$FM_TASKS_AXI_BIN"
}

# One-line description of where fm_tasks_axi_bin looked, for callers to fold
# into their own failure message when resolution finds nothing at all.
fm_tasks_axi_bin_search_summary() {
  printf 'searched PATH, %s/versions/node/*/bin, and the npm global prefix bin\n' "${NVM_DIR:-$HOME/.nvm}"
}

fm_tasks_axi_version_parts() {
  local output bin
  bin=$(fm_tasks_axi_bin) || return 1
  output=$("$bin" --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if fm_tasks_axi_compatible_probe; then
    FM_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

fm_tasks_axi_compatible_probe() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output bin
  bin=$(fm_tasks_axi_bin) || return 1
  output=$("$bin" update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output bin
  bin=$(fm_tasks_axi_bin) || return 1
  output=$("$bin" mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}

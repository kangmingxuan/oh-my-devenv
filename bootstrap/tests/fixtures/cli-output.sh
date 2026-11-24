#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=bootstrap/scripts/common.sh
source "$OUTPUT_COMMON"

sample_output() {
  log_phase 'Environment check'
  log_ok git 2.47.1
  log_ok chezmoi ''
  log_skip 'Already installed'
  log_info 'Reading configuration'
  log_would remove '~/.zshrc'
  log_next 'Open a new terminal'
  log_phase_done 3
  log_phase_done 0
  log_summary 'All checks passed.' '2 tools'
  log_missing gh 'not on PATH'
  log_warn 'Restart applications'
  log_error 'Installation failed (exit 7).' $'child output\n\nsecond line'
  log_detail 'script: install, line 29'
  log_summary_failed 'Checks failed.' '1 missing'
}

case "$OUTPUT_CASE" in
  plain|rich) sample_output ;;
  stdout_redirected) sample_output >"$OUTPUT_REDIRECTED" ;;
  stderr_redirected) sample_output 2>"$OUTPUT_REDIRECTED" ;;
  banner) print_startup_banner 'Fixture OS, arm64' ;;
  failure)
    install_error_trap fixture
    bash -c 'exit 7'
    ;;
esac

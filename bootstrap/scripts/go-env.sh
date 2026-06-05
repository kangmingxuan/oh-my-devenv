#!/usr/bin/env bash

setup_go_env() {
  export GOPATH="${GOPATH:-$HOME/go}"
  export GOBIN="${GOBIN:-$GOPATH/bin}"
  mkdir -p "$GOBIN"
}

prepend_go_bin_to_path() {
  setup_go_env
  export PATH="$GOBIN:$PATH"
}
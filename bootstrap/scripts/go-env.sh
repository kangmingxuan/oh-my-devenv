#!/usr/bin/env bash

setup_go_env() {
  export GOPATH="${GOPATH:-$HOME/go}"
  export GOBIN="${GOBIN:-$GOPATH/bin}"
  mkdir -p "$GOBIN"
}

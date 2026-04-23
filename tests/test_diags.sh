#!/bin/bash
# Test all diagnostic codes locally using the V test binary

LSP="${LSP:-$HOME/.local/bin/gaslsp}"
WORKSPACE="${WORKSPACE:-$(pwd)}"

export LSP
export WORKSPACE

$HOME/.local/bin/test_diags
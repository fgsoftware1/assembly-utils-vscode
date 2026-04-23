#!/bin/bash
# Test all diagnostic codes locally using the V test binary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LSP="${LSP:-$HOME/.local/bin/gaslsp}"

export LSP
export WORKSPACE

"$SCRIPT_DIR/test_diags"
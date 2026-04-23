#!/bin/bash
set -e

echo "=== gaslsp integration tests ==="

LSP="${LSP:-$HOME/.local/bin/gaslsp}"

test_init() {
    echo "Testing initialize..."
    resp=$(printf 'Content-Length: 81\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file:///tmp"}}' | "$LSP" 2>/dev/null)
    if ! echo "$resp" | grep -q '"capabilities"'; then
        echo "FAIL: initialize"
        exit 1
    fi
    echo "PASS: initialize"
}

test_shutdown() {
    echo "Testing shutdown..."
    init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file:///tmp"}}'
    shutdown='{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
    exit='{"jsonrpc":"2.0","id":3,"method":"exit","params":null}'
    
    resp=$(printf "Content-Length: ${#init}\r\n\r\n${init}Content-Length: ${#shutdown}\r\n\r\n${shutdown}Content-Length: ${#exit}\r\n\r\n${exit}" | "$LSP" 2>/dev/null)
    if ! echo "$resp" | grep -q '"capabilities"'; then
        echo "FAIL: shutdown sequence"
        echo "$resp"
        exit 1
    fi
    echo "PASS: shutdown"
}

test_init
test_shutdown

echo ""
echo "All tests passed!"

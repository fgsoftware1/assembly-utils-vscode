#!/bin/bash

LSP="${LSP:-$HOME/.local/bin/gaslsp}"
WORKSPACE="/home/baby/assembly-utils-vscode"

test_diag() {
    local name="$1"
    local code="$2"  
    local content="$3"
    
    echo -n "Testing $name (code $code)... "
    
    # Write temp file in workspace
    local tmpfile="$WORKSPACE/tests/tmp_${code}.s"
    echo -e "$content" > "$tmpfile"
    
    # Run LSP and check for diagnostic
    result=$(python3 -c "
import json
import subprocess
import sys

def msg(method, params, id=1):
    body = json.dumps({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})
    return f'Content-Length: {len(body)}\r\n\r\n{body}'.encode()

def notif(method, params):
    body = json.dumps({'jsonrpc': '2.0', 'method': method, 'params': params})
    return f'Content-Length: {len(body)}\r\n\r\n{body}'.encode()

LSP = '$LSP'
ws = '$WORKSPACE'

reqs = [msg('initialize', {'rootUri': f'file://{ws}'}), notif('initialized', {})]

with open('$tmpfile', 'r') as f:
    content = f.read()

reqs.append(msg('textDocument/didOpen', {
    'textDocument': {'uri': 'file://$tmpfile', 'text': content, 'version': 1}
}, id=2))

reqs.append(msg('shutdown', None, id=3))
reqs.append(notif('exit', {}))

proc = subprocess.Popen([LSP], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
stdout, stderr = proc.communicate(b''.join(reqs), timeout=5)

# Parse responses for diagnostics
import re
parts = re.split(r'Content-Length: \d+\r\n\r\n', stdout.decode())
for p in parts:
    if '$code' in p and 'publishDiagnostics' in p:
        sys.exit(0)
sys.exit(1)
" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        echo "PASS"
    else
        echo "FAIL"
    fi
    
    rm -f "$tmpfile"
}

echo "=== Testing all diagnostic codes ==="

# D001: missing suffix
test_diag "D001" "D001" "mov \$1, %rax"

# D002: inferred suffix
test_diag "D002" "D002" "mov %eax, %ebx"

# D003: size mismatch
test_diag "D003" "D003" "movl %eax, %rax"

# D004: immediate truncated
test_diag "D004" "D004" "movb \$256, %al"

# D005: high-byte + REX
test_diag "D005" "D005" "mov %ah, %r8"

# D009: 32-bit base in 64-bit
test_diag "D009" "D009" "mov (%eax), %eax"

# D010: src == dst
test_diag "D010" "D010" "add %eax, %eax"

# D011: div with immediate
test_diag "D011" "D011" "div \$4"

# D012: pushb not encodable
test_diag "D012" "D012" "pushb \$42"

# D013: one-operand imul
test_diag "D013" "D013" "imul %eax"

# D014: mul unsigned
test_diag "D014" "D014" "mul %eax"

# D015: shift count
test_diag "D015" "D015" "shl %eax, %ebx"

# D016: syscall clobber
test_diag "D016" "D016" "syscall"

# D017: int 0x80
test_diag "D017" "D017" "int \$0x80"

# D018: incomplete label
test_diag "D018" "D018" "mylabel"

# D020: TODO comment
test_diag "D020" "D020" "# TODO: fix this"

echo ""
echo "=== Tests complete ==="
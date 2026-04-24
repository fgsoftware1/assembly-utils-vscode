#!/bin/bash
# Test all diagnostic codes locally

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LSP="${LSP:-$HOME/.local/bin/gaslsp}"
WORKSPACE_BASE="${WORKSPACE:-$SCRIPT_DIR}"

test_diag() {
    local name="$1"
    local code="$2"  
    local content="$3"
    
    echo -n "Testing $name (code $code)... "
    
    # Create temp file in workspace root
    local tmpfile="$WORKSPACE_BASE/tmp_${code}.s"
    echo -e "$content" > "$tmpfile"
    
    python3 -c "
import json
import subprocess
import sys
import os

def msg(method, params, id=1):
    body = json.dumps({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})
    return ('Content-Length: %d\r\n\r\n%s' % (len(body), body)).encode()

def notif(method, params):
    body = json.dumps({'jsonrpc': '2.0', 'method': method, 'params': params})
    return ('Content-Length: %d\r\n\r\n%s' % (len(body), body)).encode()

lsp = os.environ.get('LSP', '/home/baby/.local/bin/gaslsp')
ws = os.environ.get('WORKSPACE_BASE', '$WORKSPACE_BASE')
code = '$code'

reqs = [msg('initialize', {'rootUri': 'file://' + ws}), notif('initialized', {})]

with open('$tmpfile', 'r') as f:
    file_content = f.read()

reqs.append(msg('textDocument/didOpen', {
    'textDocument': {'uri': 'file://$tmpfile', 'text': file_content, 'version': 1}
}, id=2))

reqs.append(msg('shutdown', None, id=3))
reqs.append(notif('exit', {}))

proc = subprocess.Popen([lsp], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
stdout, stderr = proc.communicate(b''.join(reqs), timeout=5)

for p in stdout.decode().split('Content-Length:'):
    if code in p and 'publishDiagnostics' in p:
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "PASS"
    else
        echo "FAIL"
    fi
    
    rm -f "$tmpfile"
}

echo "=== Testing all diagnostic codes ==="

test_diag "D001" "D001" "mov \$1, %rax"
test_diag "D012" "D012" "pushb \$42"
test_diag "D020" "D020" "# TODO: fix this"
test_diag "D002" "D002" "mov %eax, %ebx"
test_diag "D003" "D003" "movl %eax, %rax"
test_diag "D004" "D004" "movb \$256, %al"
test_diag "D005" "D005" "mov %ah, %r8"
test_diag "D009" "D009" "mov (%eax), %eax"
test_diag "D010" "D010" "add %eax, %eax"
test_diag "D011" "D011" "div \$4"
test_diag "D013" "D013" "imul %eax"
test_diag "D014" "D014" "mul %eax"
test_diag "D015" "D015" "shl %eax, %ebx"
test_diag "D016" "D016" "syscall"
test_diag "D017" "D017" "int \$0x80"
test_diag "D018" "D018" "mylabel"

echo ""
echo "=== Tests complete ==="
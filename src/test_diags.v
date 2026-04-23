module main

import os

fn run_diag(lsp_path string, workspace string, code string, content string) bool {
	tmpfile := os.join_path(workspace, 'tests', 'tmp_${code}.s')
	os.write_file(tmpfile, content) or { return false }
	defer {
		os.rm(tmpfile) or {}
	}

	escaped_content := content.replace('\\', '\\\\').replace('"', '\\"')
	escaped_tmpfile := tmpfile.replace('\\', '\\\\').replace('"', '\\"')
	escaped_workspace := workspace.replace('\\', '\\\\').replace('"', '\\"')

	init_body := "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{\"rootUri\":\"file://" + escaped_workspace + "\"},\"id\":1}"
	init_req := "Content-Length: ${init_body.len}\r\n\r\n" + init_body
	init_notif_body := "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}"
	init_notif := "Content-Length: ${init_notif_body.len}\r\n\r\n" + init_notif_body
	open_body := "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" + escaped_tmpfile + "\",\"text\":\"" + escaped_content + "\",\"version\":1}},\"id\":2}"
	open_req := "Content-Length: ${open_body.len}\r\n\r\n" + open_body
	shutdown_body := "{\"jsonrpc\":\"2.0\",\"method\":\"shutdown\",\"params\":{},\"id\":3}"
	shutdown_req := "Content-Length: ${shutdown_body.len}\r\n\r\n" + shutdown_body
	exit_body := "{\"jsonrpc\":\"2.0\",\"method\":\"exit\",\"params\":{}}"
	exit_notif := "Content-Length: ${exit_body.len}\r\n\r\n" + exit_body

	input := init_req + init_notif + open_req + shutdown_req + exit_notif

	tmp_input := os.join_path(workspace, 'tests', 'tmp_input.txt')
	os.write_file(tmp_input, input) or { return false }
	defer {
		os.rm(tmp_input) or {}
	}

tmp_output := os.join_path(workspace, 'tests', 'tmp_output.txt')
	bash_cmd := '/bin/bash -c \'cat "' + tmp_input + '" | "' + lsp_path + '" > "' + tmp_output + '"\''
	os.execute(bash_cmd)
	tmp_output_content := os.read_file(tmp_output) or {
		eprintln("Failed to read output: ${err}")
		return false
	}

	if tmp_output_content.contains(code) && tmp_output_content.contains('publishDiagnostics') {
		return true
	}
	return false
}

fn main() {
	lsp_env := os.getenv('LSP')
	lsp_path := if lsp_env.len > 0 { lsp_env } else { os.join_path(os.home_dir(), '.local', 'bin', 'gaslsp') }
	workspace_env := os.getenv('WORKSPACE')
	workspace := if workspace_env.len > 0 { workspace_env } else { os.getwd() }

	mut passed := 0
	mut failed := 0

	tests := {
		'D001': 'mov $1, %rax'
		'D002': 'mov %eax, %ebx'
		'D003': 'movl %eax, %rax'
		'D004': 'movb $256, %al'
		'D005': 'mov %ah, %r8'
		'D009': 'mov (%eax), %eax'
		'D010': 'add %eax, %eax'
		'D011': 'div $4'
		'D012': 'pushb $42'
		'D013': 'imul %eax'
		'D014': 'mul %eax'
		'D015': 'shl %eax, %ebx'
		'D016': 'syscall'
		'D017': 'int $0x80'
		'D018': 'mylabel'
		'D020': '# TODO: fix this'
	}

	println('=== Testing all diagnostic codes ===')

	for code, content in tests {
		print('Testing ${code}... ')
		if run_diag(lsp_path, workspace, code, content) {
			println('PASS')
			passed++
		} else {
			println('FAIL')
			failed++
		}
	}

	println('')
	println('=== Tests complete: ${passed} passed, ${failed} failed ===')

	if failed > 0 {
		exit(1)
	}
}
module main

import os

struct Server {
mut:
	cfg         Config
	initialized bool
	workspace   string
	tables      Tables
	indexer     Indexer
	diag        ?DiagEngine
}

fn main() {
	mut srv := Server{}
	srv.cfg = Config{}
	
	for {
		req := read_message() or { break }
		
		match req.method {
			'initialize' {
				srv.handle_initialize(req)
			}
			'initialized' {
				srv.handle_initialized(req)
			}
			'shutdown' {
				send_response(req.id, 'null')
			}
			'exit' {
				return
			}
			'textDocument/didOpen' {
				srv.handle_did_open(req)
			}
			'textDocument/didChange' {
				srv.handle_did_change(req)
			}
			'textDocument/didSave' {
				srv.handle_did_save(req)
			}
			'textDocument/hover' {
				srv.handle_hover(req)
			}
			'textDocument/definition' {
				srv.handle_definition(req)
			}
			'workspace/symbol' {
				srv.handle_workspace_symbol(req)
			}
			'workspace/didChangeConfiguration' {
				srv.handle_did_change_config(req)
				send_response(req.id, 'null')
			}
			else {
				send_response(req.id, 'null')
			}
		}
	}
}

fn (mut srv Server) handle_initialize(req RpcRequest) {
	params := req.params or {
		send_response(req.id, '{"error":{"code":-32600,"message":"Invalid params"}}')
		return
	}
	
	// Extract workspace folder - handle both object and array forms
	srv.workspace = json_raw_field(params, 'workspaceFolders') or {
		json_str_field(params, 'rootUri') or { '' }
	}
	// If workspaceFolders is an array, extract the first URI
	if srv.workspace.starts_with('[') {
		first_uri := json_raw_field(srv.workspace, 'uri') or { '' }
		srv.workspace = first_uri.trim('"')
	}
	if srv.workspace == '' {
		srv.workspace = os.getwd()
	}
	
	// Load config from workspace or default locations
	workspace_path := if srv.workspace.starts_with('file://') {
		srv.workspace['file://'.len..]
	} else {
		srv.workspace
	}
	srv.cfg = find_and_load(workspace_path)
	
	capabilities := '{
		"capabilities": {
			"textDocumentSync": 1,
			"hoverProvider": true,
			"definitionProvider": true,
			"workspaceSymbolProvider": true
		}
	}'
	send_response(req.id, capabilities)
}

fn (mut srv Server) handle_initialized(req RpcRequest) {
	srv.load_data(srv.workspace)
	if mut d := srv.diag {
		d.publish_workspace()
	}
}

fn (mut srv Server) handle_did_change_config(req RpcRequest) {
	workspace_path := if srv.workspace.starts_with('file://') {
		srv.workspace['file://'.len..]
	} else {
		srv.workspace
	}
	srv.cfg = find_and_load(workspace_path)
	// Re-init diag engine with new config
	if mut d := srv.diag {
		unsafe { d.cfg = srv.cfg }
	}
}

fn (mut srv Server) handle_did_open(req RpcRequest) {
	params := req.params or { return }
	td := json_raw_field(params, 'textDocument') or { return }
	uri := json_str_field(td, 'uri') or { return }
	path := uri_to_path(uri)
	
	if path == '' {
		return
	}
	
	srv.indexer.index_file(path)
	
	if mut d := srv.diag {
		d.publish(path)
	}
}

fn (mut srv Server) handle_did_change(req RpcRequest) {
	params := req.params or { return }
	td := json_raw_field(params, 'textDocument') or { return }
	uri := json_str_field(td, 'uri') or { return }
	path := uri_to_path(uri)
	
	if path == '' {
		return
	}
	
	content_arr := json_raw_field(params, 'contentChanges') or {
		send_response(req.id, 'null')
		return
	}
	text := json_str_field(content_arr, 'text') or {
		send_response(req.id, 'null')
		return
	}
	
	srv.indexer.index_content(path, text)
	
	// Don't publish on every change - wait for save to avoid flickering
	send_response(req.id, 'null')
}

fn (mut srv Server) handle_did_save(req RpcRequest) {
	params := req.params or { return }
	td := json_raw_field(params, 'textDocument') or { return }
	uri := json_str_field(td, 'uri') or { return }
	path := uri_to_path(uri)
	
	if path == '' {
		return
	}
	
	// Re-index file on save
	srv.indexer.index_file(path)
	
	if mut d := srv.diag {
		d.publish(path)
	}
}

fn (mut srv Server) handle_hover(req RpcRequest) {
	srv.on_hover(req)
}

fn (mut srv Server) handle_definition(req RpcRequest) {
	srv.on_definition(req)
}

fn (mut srv Server) handle_workspace_symbol(req RpcRequest) {
	srv.on_workspace_symbol(req)
}

fn uri_to_path(uri string) string {
	if uri.starts_with('file://') {
		return uri['file://'.len..]
	}
	return uri
}

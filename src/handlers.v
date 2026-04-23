// handlers.v
// LSP method handlers: hover, definition, workspace/symbol
// Wires together parser, indexer, and CSV tables

module main

import os
import encoding.csv

// ─── table types ─────────────────────────────────────────────────────────────

struct InstrEntry {
	mnemonic string
	suffixes string
	operands string
	doc      string
	flags    string
	notes    string
}

struct RegEntry {
	name   string
	family string
	bits   int
	notes  string
}

// ─── tables (loaded once at startup) ─────────────────────────────────────────

pub struct Tables {
pub mut:
	instrs []InstrEntry
	regs   []RegEntry
}

pub fn load_tables(data_dir string) Tables {
	mut t := Tables{}
	t.instrs = load_instrs(os.join_path(data_dir, 'instrs.csv'))
	t.regs = load_regs(os.join_path(data_dir, 'regs.csv'))
	return t
}

fn load_instrs(path string) []InstrEntry {
	raw := os.read_file(path) or { return [] }
	mut r := csv.new_reader(raw)
	r.read() or { return [] } // header
	mut out := []InstrEntry{}
	for {
		row := r.read() or { break }
		if row.len < 6 {
			continue
		}
		out << InstrEntry{
			mnemonic: row[0].trim_space()
			suffixes: row[1].trim_space()
			operands: row[2].trim_space()
			doc:      row[3].trim_space()
			flags:    row[4].trim_space()
			notes:    row[5].trim_space()
		}
	}
	return out
}

fn load_regs(path string) []RegEntry {
	raw := os.read_file(path) or { return [] }
	mut r := csv.new_reader(raw)
	r.read() or { return [] }
	mut out := []RegEntry{}
	for {
		row := r.read() or { break }
		if row.len < 4 {
			continue
		}
		out << RegEntry{
			name:   row[0].trim_space()
			family: row[2].trim_space()
			bits:   row[1].trim_space().int()
			notes:  row[3].trim_space()
		}
	}
	return out
}

fn (t &Tables) find_instr(mnemonic string) ?InstrEntry {
	for e in t.instrs {
		if e.mnemonic == mnemonic {
			return e
		}
	}
	return none
}

fn (t &Tables) find_reg(name string) ?RegEntry {
	for e in t.regs {
		if e.name == name {
			return e
		}
	}
	return none
}

// ─── server extension ────────────────────────────────────────────────────────

// Add to Server struct in main.v:
//   tables  Tables
//   indexer Indexer

// Called once after initialize
pub fn (mut srv Server) load_data(workspace string) {
	data_dir := resolve_data_dir()
	srv.tables = load_tables(data_dir)
	srv.indexer = new_indexer(srv.cfg)
	srv.diag = new_diag_engine(srv.cfg, srv.tables, &srv.indexer)
	if srv.cfg.indexing.scope == .workspace && workspace.len > 0 {
		srv.indexer.index_workspace(workspace)
	}
}

// ─── hover ────────────────────────────────────────────────────────────────────

pub fn (mut srv Server) on_hover(req RpcRequest) {
	params := req.params or {
		send_response(req.id, 'null')
		return
	}
	path := extract_path(params) or {
		send_response(req.id, 'null')
		return
	}
	pos_raw := json_raw_field(params, 'position') or {
		send_response(req.id, 'null')
		return
	}
	line_nr := json_int_field(pos_raw, 'line') or {
		send_response(req.id, 'null')
		return
	}
	char_nr := json_int_field(pos_raw, 'character') or {
		send_response(req.id, 'null')
		return
	}
	lines := os.read_lines(path) or {
		send_response(req.id, 'null')
		return
	}
	if line_nr >= lines.len {
		send_response(req.id, 'null')
		return
	}

	raw_line := lines[line_nr]
	word := word_at(raw_line, char_nr)
	if word.len == 0 {
		send_response(req.id, 'null')
		return
	}

	content := srv.hover_content(word, raw_line)
	if content.len == 0 {
		send_response(req.id, 'null')
		return
	}

	escaped := content
	send_response(req.id, '{"contents":{"kind":"markdown","value":"' + escaped + '"}}')
}

fn (srv &Server) hover_content(word string, raw_line string) string {
	// strip % prefix for register lookup
	clean := if word.starts_with('%') { word[1..] } else { word }
	clean_lower := clean.to_lower()

	// register hover
	if word.starts_with('%') {
		if reg := srv.tables.find_reg(clean_lower) {
			mut md := '**%${reg.name}** — ${reg.bits}-bit'
			if reg.notes.len > 0 {
				md += '\\n\\n${reg.notes}'
			}
			return md
		}
		return ''
	}

	// instruction hover — try exact then strip suffix
	parsed := parse_line(raw_line, 0)
	mnemonic := if parsed.kind == .instruction || parsed.kind == .label_and_instruction {
		parsed.mnemonic
	} else {
		clean_lower
	}

	if instr := srv.tables.find_instr(mnemonic) {
		mut md := '**${mnemonic}**'
		if instr.suffixes.len > 0 {
			md += '`${instr.suffixes}`'
		}
		if instr.operands.len > 0 {
			md += ' *${instr.operands}*'
		}
		md += '\\n\\n${instr.doc}'
		if instr.flags != 'none' && instr.flags.len > 0 {
			md += '\\n\\n**Flags:** ${instr.flags}'
		}
		if instr.notes.len > 0 {
			md += '\\n\\n> ${instr.notes}'
		}
		// inferred size warning
		if parsed.suffix == 0 && parsed.operands.len > 0 {
			has_reg := parsed.operands.any(it.kind == .register)
			if has_reg && srv.cfg.infer.warn_inferred_size {
				md += '\\n\\n⚠ *No size suffix — size inferred from operand*'
			}
		}
		return md
	}

	// symbol hover
	if sym := srv.indexer.index.find(clean_lower) {
		vis := match sym.vis {
			.global { 'global' }
			.local { 'local' }
			.extern { 'extern' }
		}
		return '**${sym.name}** — ${vis} label\\n\\n${os.base(sym.file)}:${sym.line_nr}'
	}

	return ''
}

// ─── definition ───────────────────────────────────────────────────────────────

pub fn (mut srv Server) on_definition(req RpcRequest) {
	params := req.params or {
		send_response(req.id, 'null')
		return
	}
	path := extract_path(params) or {
		send_response(req.id, 'null')
		return
	}
	pos_raw := json_raw_field(params, 'position') or {
		send_response(req.id, 'null')
		return
	}
	line_nr := json_int_field(pos_raw, 'line') or {
		send_response(req.id, 'null')
		return
	}
	char_nr := json_int_field(pos_raw, 'character') or {
		send_response(req.id, 'null')
		return
	}
	lines := os.read_lines(path) or {
		send_response(req.id, 'null')
		return
	}
	if line_nr >= lines.len {
		send_response(req.id, 'null')
		return
	}

	word := word_at(lines[line_nr], char_nr)
	if word.len == 0 {
		send_response(req.id, 'null')
		return
	}

	sym := srv.indexer.index.find(word) or {
		send_response(req.id, 'null')
		return
	}

	result := location_json(path_to_uri(sym.file), sym.line_nr - 1, 0)
	send_response(req.id, result)
}

// ─── did change ───────────────────────────────────────────────────────────────

pub fn (mut srv Server) on_did_change(req RpcRequest) {
	params := req.params or { return }
	path := extract_path(params) or { return }

	// try to get content from params (didChange sends it), else re-read from disk
	if content_arr := json_raw_field(params, 'contentChanges') {
		// take last change's text (full sync mode — textDocumentSync: 1)
		if text := json_str_field(content_arr, 'text') {
			srv.indexer.index_content(path, text)
			return
		}
	}
	srv.indexer.index_file(path)
}

// ─── workspace symbol ─────────────────────────────────────────────────────────

pub fn (mut srv Server) on_workspace_symbol(req RpcRequest) {
	params := req.params or {
		send_response(req.id, '[]')
		return
	}
	query := json_str_field(params, 'query') or { '' }

	mut results := []string{}
	for name, syms in srv.indexer.index.symbols {
		if query.len > 0 && !name.contains(query) {
			continue
		}
		for s in syms {
			results << symbol_info_json(s)
		}
	}
	send_response(req.id, '[${results.join(',')}]')
}

// ─── helpers ──────────────────────────────────────────────────────────────────

// Extract the word (label/mnemonic/register) at a character offset
fn word_at(line string, char_pos int) string {
	if char_pos > line.len {
		return ''
	}
	is_word := fn (c u8) bool {
		return c.is_letter() || c.is_digit() || c == `_` || c == `.` || c == `%` || c == `$`
	}
	mut start := char_pos
	mut end := char_pos
	for start > 0 && is_word(line[start - 1]) {
		start--
	}
	for end < line.len && is_word(line[end]) {
		end++
	}
	if start == end {
		return ''
	}
	// include leading % or $ only if at start of token
	return line[start..end]
}

fn location_json(uri_ string, line int, col int) string {
	loc := '{"uri":"' + uri_ + '","range":{"start":{"line":' + line.str() + ',"character":' + col.str() + '},"end":{"line":' + line.str() + ',"character":' + col.str() + '}}}'
	return loc
}

fn symbol_info_json(s Symbol) string {
	kind := 14
	uri_ := path_to_uri(s.file)
	loc := location_json(uri_, s.line_nr - 1, 0)
	return '{"name":"' + s.name + '","kind":' + kind.str() + ',"location":' + loc + '}'
}

// Extract file path from textDocument params (handles both flat and nested uri)
fn extract_path(params string) ?string {
	uri := json_str_field(params, 'uri') or {
		td := json_raw_field(params, 'textDocument') or { return none }
		json_str_field(td, 'uri') or { return none }
	}
	return if uri.starts_with('file://') { uri['file://'.len..] } else { uri }
}

fn path_to_uri(path string) string {
	return 'file://' + path
}

// Resolve directory where CSV data files live:
//   1. GASLSP_DATA env var
//   2. next to binary
//   3. ~/.config/gaslsp/
fn resolve_data_dir() string {
	if d := os.getenv_opt('GASLSP_DATA') {
		if os.exists(d) { return d }
	}
	bin_dir := os.dir(os.executable())
	if os.exists(os.join_path(bin_dir, 'instrs.csv')) {
		return bin_dir
	}
	home := os.join_path(os.home_dir(), '.config', 'gaslsp')
	return home
}

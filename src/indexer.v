// indexer.v
// Walks workspace files, parses them, builds symbol table

module main

import os

// ─── symbol table ─────────────────────────────────────────────────────────────

pub enum SymbolVis {
	local  // not .global
	global // declared .global
	extern // declared .extern
}

pub struct Symbol {
pub:
	name    string
	vis     SymbolVis
	file    string
	line_nr int
}

pub struct Index {
pub mut:
	symbols map[string][]Symbol // name → all definitions (catches duplicates)
	files   []string            // indexed file paths
}

pub fn (idx &Index) find(name string) ?Symbol {
	syms := idx.symbols[name] or { return none }
	if syms.len == 0 {
		return none
	}
	return syms[0]
}

pub fn (idx &Index) find_all(name string) []Symbol {
	return idx.symbols[name] or { []Symbol{} }
}

// ─── indexer ──────────────────────────────────────────────────────────────────

@[heap]
pub struct Indexer {
pub mut:
	cfg   Config
	index Index
}

pub fn new_indexer(cfg Config) Indexer {
	return Indexer{
		cfg: cfg
	}
}

// Index a whole workspace root according to config scope
pub fn (mut ix Indexer) index_workspace(root string) {
	match ix.cfg.indexing.scope {
		.workspace { ix.walk_dir(root) }
		.includes {} // driven per-file via index_file_with_includes
		.open {} // driven per open notification
	}
}

// Index a single file — called on didOpen / didChange / didSave
pub fn (mut ix Indexer) index_file(path string) {
	lines := os.read_lines(path) or { return }
	ix.index_lines(path, lines)

	if ix.cfg.indexing.scope == .includes {
		ix.follow_includes(path, lines)
	}
}

// Re-index a file from already-read content (avoids double disk read)
pub fn (mut ix Indexer) index_content(path string, content string) {
	lines := content.split_into_lines()
	ix.index_lines(path, lines)
}

// Remove all symbols from a file (called before re-indexing it)
pub fn (mut ix Indexer) remove_file(path string) {
	for name, mut syms in ix.index.symbols {
		ix.index.symbols[name] = syms.filter(it.file != path)
	}
	ix.index.files = ix.index.files.filter(it != path)
}

// ─── internals ────────────────────────────────────────────────────────────────

fn (mut ix Indexer) walk_dir(dir string) {
	entries := os.ls(dir) or { return }
	for entry in entries {
		full := os.join_path(dir, entry)
		if os.is_dir(full) {
			if ix.cfg.general.recursive {
				ix.walk_dir(full)
			}
			continue
		}
		if ix.is_asm_file(full) {
			ix.index_file(full)
		}
	}
}

fn (mut ix Indexer) index_lines(path string, lines []string) {
	// remove stale entries first
	ix.remove_file(path)
	ix.index.files << path

	mut globals := map[string]bool{}

	// first pass: collect .global / .extern declarations
	for i, raw in lines {
		l := parse_line(raw, i + 1)
		if l.kind != .directive {
			continue
		}
		match l.directive {
			'global', 'globl' {
				for name in l.dir_args.split(',') {
					globals[name.trim_space()] = true
				}
			}
			else {}
		}
	}

	// second pass: collect label definitions
	for i, raw in lines {
		l := parse_line(raw, i + 1)
		if l.label.len == 0 {
			continue
		}
		name := l.label
		vis := if name in globals { SymbolVis.global } else { SymbolVis.local }
		sym := Symbol{
			name:    name
			vis:     vis
			file:    path
			line_nr: i + 1
		}
		if name !in ix.index.symbols {
			ix.index.symbols[name] = []Symbol{}
		}
		ix.index.symbols[name] << sym
	}
}

fn (mut ix Indexer) follow_includes(path string, lines []string) {
	base := os.dir(path)
	for i, raw in lines {
		l := parse_line(raw, i + 1)
		if l.directive != 'include' {
			continue
		}
		inc_path := resolve_include(l.dir_args, base, ix.cfg)
		if inc_path.len == 0 || inc_path in ix.index.files {
			continue
		}
		ix.index_file(inc_path)
	}
}

fn resolve_include(arg string, base string, cfg Config) string {
	// strip quotes: "file.s" or <file.s>
	raw := arg.trim_space().trim('"').trim('<').trim('>')
	if raw.len == 0 {
		return ''
	}

	candidate := if os.is_abs_path(raw) { raw } else { os.join_path(base, raw) }

	if os.exists(candidate) {
		// check if outside workspace — respect follow_external_includes
		if !cfg.indexing.follow_external_includes {
			// simple check: if it doesn't share the base prefix, skip
			// a real impl would compare against workspace root
			if !candidate.starts_with(base) {
				return ''
			}
		}
		return candidate
	}

	// check extra_dirs
	for dir in cfg.indexing.extra_dirs {
		p := os.join_path(dir, raw)
		if os.exists(p) {
			return p
		}
	}
	return ''
}

fn (ix &Indexer) is_asm_file(path string) bool {
	for ext in ix.cfg.general.extensions {
		if path.ends_with(ext) {
			return true
		}
	}
	return false
}

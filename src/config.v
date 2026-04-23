// config.v
// Parses gaslsp.toml into a Config struct.
// Minimal hand-rolled TOML parser — only handles the subset used by gaslsp.toml.
// No external dependencies.

module main

import os

pub struct DiagCategories {
pub mut:
	size        bool = true
	truncation  bool = true
	register    bool = true
	symbol      bool = true
	directive   bool = true
	operand     bool = true
	encoding    bool = true
	abi         bool = true
	state       bool = true
	statements  bool = true
}

pub struct DiagLevels {
pub mut:
	error   bool = true
	warning bool = true
	hint    bool = true
}

pub struct DiagConfig {
pub mut:
	enabled            bool = true
	suppress           []string
	categories         DiagCategories
	levels             DiagLevels
	warnings_as_errors []string
}

pub struct InferConfig {
pub mut:
	warn_inferred_size bool = true
	warn_mode_mismatch bool = true
}

pub struct SymbolConfig {
pub mut:
	warn_dead_exports   bool
	warn_missing_global bool = true
}

pub struct AbiConfig {
pub mut:
	convention           string = 'sysv'
	warn_syscall_clobber bool   = true
	warn_legacy_syscall  bool   = true
}

pub enum IndexScope {
	workspace
	includes
	open
}

pub struct IndexingConfig {
pub mut:
	scope                    IndexScope = .workspace
	follow_external_includes bool
	extra_dirs               []string
}

pub struct GeneralConfig {
pub mut:
	mode       string   = 'auto'
	extensions []string = ['.s', '.S', '.asm']
	recursive  bool     = true
}

pub struct Config {
pub mut:
	general     GeneralConfig
	diagnostics DiagConfig
	infer       InferConfig
	symbols     SymbolConfig
	abi         AbiConfig
	indexing    IndexingConfig
}

// Load config from path. Falls back to defaults if file missing.
pub fn load(path string) Config {
	mut cfg := Config{}
	content := os.read_file(path) or { return cfg }
	parse_toml(content, mut cfg)
	return cfg
}

// Find config: project root first, then ~/.config/gaslsp/gaslsp.toml
pub fn find_and_load(workspace string) Config {
	project_cfg := os.join_path(workspace, 'gaslsp.toml')
	if os.exists(project_cfg) {
		return load(project_cfg)
	}
	home := os.home_dir()
	user_cfg := os.join_path(home, '.config', 'gaslsp', 'gaslsp.toml')
	if os.exists(user_cfg) {
		return load(user_cfg)
	}
	return Config{}
}

// Check if a diagnostic code is suppressed
pub fn (c &Config) is_suppressed(code string) bool {
	if !c.diagnostics.enabled {
		return true
	}
	if code in c.diagnostics.suppress {
		return true
	}
	return false
}

// Check if a diagnostic should be emitted as error (promotion)
pub fn (c &Config) is_error(code string, original_level string) bool {
	if original_level == 'error' {
		return true
	}
	if code in c.diagnostics.warnings_as_errors {
		return true
	}
	return false
}

// ─── parser ──────────────────────────────────────────────────────────────────
// Handles: [section], [section.subsection], key = value, key = [array], # comments

fn parse_toml(content string, mut cfg Config) {
	mut section := ''
	for raw_line in content.split_into_lines() {
		line := raw_line.trim_space()
		if line.starts_with('#') || line.len == 0 {
			continue
		}

		// section header
		if line.starts_with('[') && line.ends_with(']') {
			section = line[1..line.len - 1].trim_space()
			continue
		}

		// key = value
		eq := line.index('=') or { continue }
		key := line[..eq].trim_space()
		value := line[eq + 1..].trim_space()

		apply(key, value, section, mut cfg)
	}
}

fn apply(key string, value string, section string, mut cfg Config) {
	// strip inline comments from value
	comment_idx := value.index('#') or { -1 }
	clean_value := if comment_idx >= 0 { value[..comment_idx] } else { value }.trim_space()
	match section {
		'indexing' {
			match key {
				'scope' {
					cfg.indexing.scope = match unquote(clean_value) {
						'includes' { IndexScope.includes }
						'open' { IndexScope.open }
						else { IndexScope.workspace }
					}
				}
				'follow_external_includes' {
					cfg.indexing.follow_external_includes = clean_value == 'true'
				}
				'extra_dirs' {
					cfg.indexing.extra_dirs = parse_str_array(clean_value)
				}
				else {}
			}
		}
		'general' {
			match key {
				'mode' { cfg.general.mode = unquote(clean_value) }
				'recursive' { cfg.general.recursive = clean_value == 'true' }
				'extensions' { cfg.general.extensions = parse_str_array(clean_value) }
				else {}
			}
		}
		'diagnostics' {
			match key {
				'enabled' { cfg.diagnostics.enabled = clean_value == 'true' }
				'suppress' { cfg.diagnostics.suppress = parse_str_array(clean_value) }
				'warnings_as_errors' { cfg.diagnostics.warnings_as_errors = parse_str_array(clean_value) }
				else {}
			}
		}
		'diagnostics.categories' {
			v := clean_value == 'true'
			match key {
				'size' { cfg.diagnostics.categories.size = v }
				'truncation' { cfg.diagnostics.categories.truncation = v }
				'register' { cfg.diagnostics.categories.register = v }
				'symbol' { cfg.diagnostics.categories.symbol = v }
				'directive' { cfg.diagnostics.categories.directive = v }
				'operand' { cfg.diagnostics.categories.operand = v }
				'encoding' { cfg.diagnostics.categories.encoding = v }
				'abi' { cfg.diagnostics.categories.abi = v }
				'state' { cfg.diagnostics.categories.state = v }
				'statements' { cfg.diagnostics.categories.statements = v }
				else {}
			}
		}
		'diagnostics.levels' {
			v := clean_value == 'true'
			match key {
				'error' { cfg.diagnostics.levels.error = v }
				'warning' { cfg.diagnostics.levels.warning = v }
				'hint' { cfg.diagnostics.levels.hint = v }
				else {}
			}
		}
		'infer' {
			v := clean_value == 'true'
			match key {
				'warn_inferred_size' { cfg.infer.warn_inferred_size = v }
				'warn_mode_mismatch' { cfg.infer.warn_mode_mismatch = v }
				else {}
			}
		}
		'symbols' {
			v := clean_value == 'true'
			match key {
				'warn_dead_exports' { cfg.symbols.warn_dead_exports = v }
				'warn_missing_global' { cfg.symbols.warn_missing_global = v }
				else {}
			}
		}
		'abi' {
			match key {
				'convention' { cfg.abi.convention = unquote(clean_value) }
				'warn_syscall_clobber' { cfg.abi.warn_syscall_clobber = clean_value == 'true' }
				'warn_legacy_syscall' { cfg.abi.warn_legacy_syscall = clean_value == 'true' }
				else {}
			}
		}
		else {}
	}
}

// "hello" → hello
fn unquote(s string) string {
	if s.starts_with('"') && s.ends_with('"') {
		return s[1..s.len - 1]
	}
	return s
}

// ["D001", "D002"] → ['D001', 'D002']
fn parse_str_array(s string) []string {
	trimmed := s.trim_space()
	if !trimmed.starts_with('[') {
		return []
	}
	inner := trimmed[1..trimmed.len - 1]
	if inner.trim_space().len == 0 {
		return []
	}
	mut result := []string{}
	for part in inner.split(',') {
		v := unquote(part.trim_space())
		if v.len > 0 {
			result << v
		}
	}
	return result
}

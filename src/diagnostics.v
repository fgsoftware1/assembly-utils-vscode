// diagnostics.v
// Runs diagnostic checks on parsed lines and publishes results via LSP

module main

import os
import encoding.csv

// ─── types ────────────────────────────────────────────────────────────────────

pub enum DiagSeverity {
	error   = 1
	warning = 2
	hint    = 3
}

pub struct DiagRange {
pub:
	line      int
	col_start int
	col_end   int
}

pub struct Diag {
pub:
	code     string
	severity DiagSeverity
	message  string
	range    DiagRange
}

// ─── register tracking ─────────────────────────────────────────────────────────

struct RegisterTracker {
mut:
	initialized map[string]bool  // which registers have been written
}

fn new_register_tracker() RegisterTracker {
	return RegisterTracker{}
}

fn (mut t RegisterTracker) reset() {
	t.initialized = map[string]bool{}
}

fn (t &RegisterTracker) is_init(reg string) bool {
	return t.initialized[reg]
}

fn (mut t RegisterTracker) mark_init(reg string) {
	t.initialized[reg] = true
}

fn (mut t RegisterTracker) mark_clobbered(reg string) {
	t.initialized[reg] = false
}

// Clobber registers modified by an instruction
fn (mut t RegisterTracker) clobber_instr(mnemonic string) {
	match mnemonic {
		'div', 'idiv' {
		}
		'call' {
		}
		'ret' {
		}
		else {}
	}
}

// Check if a register is read before being initialized
fn (t &RegisterTracker) check_uninit_read(reg string) bool {
	return !t.is_init(reg)
}

// Get full-width register name (e.g., "eax" -> "rax")
fn full_reg(reg string) string {
	return match reg {
		'al', 'ah', 'ax', 'eax', 'rax' { 'rax' }
		'bl', 'bh', 'bx', 'ebx', 'rbx' { 'rbx' }
		'cl', 'ch', 'cx', 'ecx', 'rcx' { 'rcx' }
		'dl', 'dh', 'dx', 'edx', 'rdx' { 'rdx' }
		'si', 'esi', 'rsi' { 'rsi' }
		'di', 'edi', 'rdi' { 'rdi' }
		'bp', 'ebp', 'rbp' { 'rbp' }
		'sp', 'esp', 'rsp' { 'rsp' }
		'bpl' { 'rbp' }
		'spl' { 'rsp' }
		else { reg }
	}
}

// Callee-saved registers on x86-64 Linux
fn is_callee_saved(reg string) bool {
	full := full_reg(reg)
	return full in ['rbx', 'rbp', 'r12', 'r13', 'r14', 'r15']
}

// ─── diag table entry ─────────────────────────────────────────────────────────

struct DiagDef {
	code     string
	level    string
	category string
	template string
}

// ─── engine ───────────────────────────────────────────────────────────────────

pub struct DiagEngine {
pub mut:
	cfg     Config
	defs    []DiagDef
	tables  Tables
	indexer ?&Indexer
}

pub fn new_diag_engine(cfg Config, tables Tables, indexer &Indexer) DiagEngine {
	data_dir := resolve_data_dir()
	defs := load_diag_defs(os.join_path(data_dir, 'diagnostics.csv'))
	return DiagEngine{
		cfg:     cfg
		defs:    defs
		tables:  tables
		indexer: indexer
	}
}

fn (eng &DiagEngine) get_indexer() &Indexer {
	return eng.indexer or { panic('DiagEngine: indexer not set') }
}

fn load_diag_defs(path string) []DiagDef {
	raw := os.read_file(path) or { return [] }
	mut r := csv.new_reader(raw)
	r.read() or { return [] }
	mut out := []DiagDef{}
	for {
		row := r.read() or { break }
		if row.len < 4 {
			continue
		}
		out << DiagDef{
			code:     row[0].trim_space()
			level:    row[1].trim_space()
			category: row[2].trim_space()
			template: row[3].trim_space()
		}
	}
	return out
}

// ─── publish ──────────────────────────────────────────────────────────────────

// Run all checks on a file and publish diagnostics
pub fn (mut eng DiagEngine) publish(path string) {
	if !eng.cfg.diagnostics.enabled {
		return
	}

	lines := os.read_lines(path) or { return }
	mut diags := []Diag{}

	// track .global declarations for cross-check
	mut globals := map[string]bool{}
	for i, raw in lines {
		l := parse_line(raw, i + 1)
		if l.directive == 'global' || l.directive == 'globl' {
			for name in l.dir_args.split(',') {
				globals[name.trim_space()] = true
			}
		}
	}

	// register tracking for uninitialized reads
	mut tracker := new_register_tracker()
	mut in_function := false

	for i, raw in lines {
		l := parse_line(raw, i + 1)
		line_diags := eng.check_line(l, raw, globals, path)
		diags << line_diags

		// Register tracking
		if l.kind == .label {
			// Reset tracker at function entry points
			if l.label == '_start' || l.label == 'main' || l.label.ends_with(':entry') {
				tracker.reset()
				in_function = true
			}
		}

		if !in_function || (l.kind != .instruction && l.kind != .label_and_instruction) {
			continue
		}

		// Check for uninitialized reads
		if eng.enabled('D034') && eng.cfg.diagnostics.categories.state && l.kind == .instruction {
			// Source operands (all but last in AT&T syntax)
			for idx := 0; idx < l.operands.len - 1; idx++ {
				op := l.operands[idx]
				if op.kind == .register {
					full := full_reg(op.reg)
					if tracker.check_uninit_read(full) {
						diags << Diag{
							code: 'D034'
							severity: .warning
							message: "'${op.raw}' may be uninitialized (not written before this read)"
							range: DiagRange{ line: i, col_start: 0, col_end: raw.len }
						}
					}
				}
			}
		}

		// Mark registers as initialized after write instructions
		if l.kind == .instruction {
			dst_reg := register_written_by(l.mnemonic, l.operands)
			if dst_reg.len > 0 {
				tracker.mark_init(dst_reg)
				// For div/imul, both EDX and EAX are used and result affects both
				if l.mnemonic == 'div' || l.mnemonic == 'idiv' || l.mnemonic == 'mul' || l.mnemonic == 'imul' {
					tracker.mark_init('rdx')
					tracker.mark_init('rax')
				}
			}
			// xor reg, reg marks reg as initialized (zeroing idiom)
			// In AT&T: xor %eax, %eax means src=dst, so only one reg
			if l.mnemonic == 'xor' && l.operands.len >= 2 {
				if l.operands[0].kind == .register && l.operands[0].reg == l.operands[1].reg {
					tracker.mark_init(full_reg(l.operands[0].reg))
				}
			}
			// mov: dst is last operand
			if l.mnemonic == 'mov' || l.mnemonic == 'movq' || l.mnemonic == 'movl' || l.mnemonic == 'movw' || l.mnemonic == 'movb' {
				if l.operands.len > 0 {
					last := l.operands[l.operands.len - 1]
					if last.kind == .register {
						tracker.mark_init(full_reg(last.reg))
					}
				}
			}
			// push doesn't init registers, pop does (AT&T: pop %dst)
			if l.mnemonic == 'pop' && l.operands.len > 0 {
				last := l.operands[l.operands.len - 1]
				if last.kind == .register {
					tracker.mark_init(full_reg(last.reg))
				}
			}
			// lea doesn't write registers (AT&T: lea 8(%rax), %rbx)
			// Function calls clobber caller-saved registers
			if l.mnemonic == 'call' {
				for r in caller_saved_regs() {
					tracker.mark_clobbered(r)
				}
			}
		}
	}

	// cross-file symbol checks
	diags << eng.check_symbols(path, lines, globals)

	uri := path_to_uri(path)
	arr := diags.map(diag_to_json(it)).join(",")
	json_body := '{"uri":"' + uri + '","diagnostics":[' + arr + ']}'
	send_notification("textDocument/publishDiagnostics", json_body)
}

// Returns the register written by an instruction (for init tracking)
// In AT&T syntax: mov %src, %dst - dst is LAST operand
fn register_written_by(mnemonic string, operands []Operand) string {
	if operands.len == 0 {
		return ''
	}
	// Destination is LAST operand in AT&T syntax
	last := operands[operands.len - 1]
	if last.kind == .register {
		return full_reg(last.reg)
	}
	// For ALU ops with memory dest, no register is written
	if last.kind == .memory {
		return ''
	}
	return ''
}

// Returns registers READ by an instruction (source operands)
// In AT&T syntax: mov %src, %dst - src is ALL BUT LAST operand
fn registers_read(mnemonic string, operands []Operand) []string {
	mut regs := []string{}
	// All operands except the last one are sources (reads)
	for i := 0; i < operands.len - 1; i++ {
		op := operands[i]
		if op.kind == .register {
			regs << full_reg(op.reg)
		}
	}
	return regs
}

fn caller_saved_regs() []string {
	return ['rax', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11']
}

pub fn (mut eng DiagEngine) publish_workspace() {
	ix := eng.get_indexer()
	for path in ix.index.files {
		eng.publish(path)
	}
}

// ─── line checks ─────────────────────────────────────────────────────────────

fn (eng &DiagEngine) check_line(l Line, raw string, globals map[string]bool, path string) []Diag {
	mut diags := []Diag{}
	
	// D018 incomplete label - line has label-like content but no colon
	stripped := raw.trim_space()
	if stripped.len > 0 && !stripped.starts_with('.') && !stripped.starts_with('#') && !stripped.contains(':') {
		first_word := stripped.split(' ')[0].split('	')[0]
		if first_word.len > 0 {
			if _ := eng.tables.find_instr(first_word) {
				// first_word is an instruction, not a label
			} else {
				instr_match := stripped.index(' ') or { stripped.len }
				rest := stripped[instr_match..].trim_space()
				if rest.len == 0 || rest.starts_with('#') {
					if eng.enabled('D018') && eng.cfg.diagnostics.categories.operand {
						diags << eng.make(l, raw, 'D018', .error, "incomplete label: '${first_word}' has no colon")
					}
				}
			}
		}
	}
	
	// TODO check - comments containing TODO/FIXME/HACK/XXX
	if eng.enabled('D020') && eng.cfg.diagnostics.categories.statements {
		todo_patterns := ['TODO', 'FIXME', 'HACK', 'XXX', 'BUG']
		upper := stripped.to_upper()
		for pattern in todo_patterns {
			if upper.contains(pattern) {
				diags << eng.make(l, raw, 'D020', .hint, "TODO comment found: '${pattern}' - consider addressing this")
				break
			}
		}
	}
	
	if l.kind != .instruction && l.kind != .label_and_instruction {
		return diags
	}

	diags << eng.check_size(l, raw)
	diags << eng.check_operands(l, raw)
	diags << eng.check_encoding(l, raw)
	diags << eng.check_abi(l, raw)

	return diags
}

// D001 missing suffix, D002 inferred suffix, D003 mismatch
fn (eng &DiagEngine) check_size(l Line, raw string) []Diag {
	mut diags := []Diag{}

	reg_ops := l.operands.filter(it.kind == .register)

	// check if instruction is known to accept suffixes
	if instr := eng.tables.find_instr(l.mnemonic) {
		if instr.suffixes.len == 0 {
			return diags
		}
	}

	if l.suffix == 0 {
		// For shift instructions with invalid count, only show D028, not D002
		is_shift := l.mnemonic in ['shl', 'shr', 'sar']
		invalid_count := is_shift && l.operands.len >= 1 && 
			l.operands[0].kind == .register && l.operands[0].reg != 'cl'
		
		if reg_ops.len == 0 {
			// No register operands to infer from
			if eng.enabled('D001') {
				diags << eng.make(l, raw, 'D001', .error, "suffix or operands needed for '${l.mnemonic}'")
			}
		} else if !invalid_count {
			if eng.enabled('D002') && eng.cfg.infer.warn_inferred_size {
				inferred := suffix_for_width(reg_ops[0].width)
				diags << eng.make(l, raw, 'D002', .warning, "no size suffix on '${l.mnemonic}', inferring ${inferred} from operand '%${reg_ops[0].reg}'")
			}
		}
	} else {
		// explicit suffix — check consistency against register operands
		suffix_bits := suffix_width(l.suffix)
		if suffix_bits > 0 {
			mismatched := reg_ops.filter(it.width > 0 && it.width != suffix_bits)
			if mismatched.len > 0 && eng.enabled('D003') {
				op := mismatched[0]
				diags << eng.make(l, raw, 'D003', .error, "operand size mismatch: '${l.mnemonic}' has suffix '${l.suffix.ascii_str()}' (${suffix_bits}-bit) but '%${op.reg}' is ${op.width}-bit")
			}
		}
	}

	return diags
}

// D004 truncation, D005 REX+high-byte, D009 32-bit mem in 64-bit
fn (eng &DiagEngine) check_operands(l Line, raw string) []Diag {
	mut diags := []Diag{}
	suffix_bits := if l.suffix != 0 { suffix_width(l.suffix) } else { 0 }

	for op in l.operands {
		match op.kind {
			.immediate {
				if suffix_bits > 0 {
					min_s := min_signed(suffix_bits)
					max_s := max_signed(suffix_bits)
					if op.imm < min_s || op.imm > max_s {
						if eng.enabled('D004') {
							diags << eng.make(l, raw, 'D004', .warning, 'immediate ${op.raw} truncated: value ${op.imm} does not fit in ${suffix_bits} bits (range ${min_s}..${max_s})')
						}
					}
				}
			}
			.register {
				high_byte := op.reg in ['ah', 'bh', 'ch', 'dh']
				rex_regs := l.operands.any(it.kind == .register
					&& it.reg in ['sil', 'dil', 'spl', 'bpl', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15', 'r8b', 'r9b', 'r10b', 'r11b', 'r12b', 'r13b', 'r14b', 'r15b', 'r8w', 'r9w', 'r10w', 'r11w', 'r12w', 'r13w', 'r14w', 'r15w', 'r8d', 'r9d', 'r10d', 'r11d', 'r12d', 'r13d', 'r14d', 'r15d'])
				if high_byte && rex_regs && eng.enabled('D005') {
					diags << eng.make(l, raw, 'D005', .error, "high-byte register (%ah, %bh, %ch, %dh) conflicts with REX prefix")
				}
			}
			.memory {
				// D009 — 32-bit base register in memory operand
				// crude check: look for (%e__) pattern
				if op.raw.contains('(%e') && eng.enabled('D009') {
					diags << eng.make(l, raw, 'D009', .error, "memory operand '${op.raw}' uses 32-bit base register in 64-bit mode; consider using the 64-bit equivalent")
				}
			}
			else {}
		}
	}

	// D010 src == dst — check once per instruction
	if l.operands.len == 2 && l.mnemonic != 'xor' {
		src, dst := l.operands[0], l.operands[1]
		if src.kind == .register && dst.kind == .register && src.reg == dst.reg
			&& eng.enabled('D010') {
			diags << eng.make(l, raw, 'D010', .warning, "'${l.mnemonic}': source and destination are the same register '%${src.reg}'; instruction has no effect")
		}
	}

	return diags
}

// D011 div-by-immediate, D012 pushb, D013 one-operand imul, D014 mul unsigned, D015 shift count
fn (eng &DiagEngine) check_encoding(l Line, raw string) []Diag {
	mut diags := []Diag{}

	match l.mnemonic {
		'div', 'idiv' {
			// D011 — div with immediate
			if l.operands.any(it.kind == .immediate) && eng.enabled('D011') {
				diags << eng.make(l, raw, 'D011', .error, "'${l.mnemonic}' does not support immediate operands; load divisor into a register first")
			}
		}
		'imul' {
			// D013 — one-operand imul
			if l.operands.len == 1 && eng.enabled('D013') {
				diags << eng.make(l, raw, 'D013', .warning, "'imul' one-operand form: high half of result in rdx may be unexpected; did you want the two-operand form?")
			}
		}
		'mul' {
			// D014 — mul vs imul
			if eng.enabled('D014') {
				diags << eng.make(l, raw, 'D014', .warning, "'mul' is unsigned multiply; upper half stored in rdx may be silently discarded; use 'imul' if signed")
			}
		}
		'shl', 'shr', 'sar' {
			// D015 — shift count must be imm8 or %cl
			if l.operands.len >= 1 {
				count := l.operands[0]
				if count.kind == .register && count.reg != 'cl' && eng.enabled('D015') {
					diags << eng.make(l, raw, 'D015', .error, "shift count must be %cl or an immediate; '%${count.reg}' is not encodable")
				}
			}
		}
		'push' {
			// D012 — pushb not encodable
			if l.suffix == `b` && eng.enabled('D012') {
				diags << eng.make(l, raw, 'D012', .error, "'pushb' is not encodable; push only supports 16/32/64-bit operands")
			}
		}
		else {}
	}

	return diags
}

// D016 syscall clobber, D017 int $0x80
fn (eng &DiagEngine) check_abi(l Line, raw string) []Diag {
	mut diags := []Diag{}
	if !eng.cfg.diagnostics.categories.abi {
		return diags
	}

	match l.mnemonic {
		'syscall' {
			if eng.enabled('D016') && eng.cfg.abi.warn_syscall_clobber {
				diags << eng.make(l, raw, 'D016', .warning, "'syscall' clobbers %rcx and %r11; save them if their values are needed after the call")
			}
		}
		'int' {
			if l.operands.len > 0 && l.operands[0].raw == '$0x80' {
				if eng.enabled('D017') && eng.cfg.abi.warn_legacy_syscall {
					diags << eng.make(l, raw, 'D017', .warning, "'int $0x80' is the 32-bit Linux syscall ABI; arguments are truncated to 32 bits in 64-bit mode; use 'syscall' instead")
				}
			}
		}
		else {}
	}

	return diags
}

// D006 undefined symbol, D007 missing .global, D008 duplicate, D019 not exported
fn (eng &DiagEngine) check_symbols(path string, lines []string, globals map[string]bool) []Diag {
	mut diags := []Diag{}
	
	// D019: _start defined but not declared .global
	mut has_start := false
	mut has_global_start := false
	for i, raw in lines {
		l := parse_line(raw, i + 1)
		if l.kind == .label && (l.label == '_start' || l.label == 'main') {
			has_start = true
			if l.label in globals {
				has_global_start = true
			}
		}
	}
	if has_start && !has_global_start && eng.enabled('D019') {
		for i, raw in lines {
			l := parse_line(raw, i + 1)
			if l.kind == .label && (l.label == '_start' || l.label == 'main') {
				diags << Diag{
					code: 'D019'
					severity: .warning
					message: "'${l.label}' defined but not exported"
					range: DiagRange{ line: i, col_start: 0, col_end: raw.len }
				}
			}
		}
	}
	if !eng.cfg.diagnostics.categories.symbol {
		return diags
	}

	// collect references in this file
	for i, raw in lines {
		l := parse_line(raw, i + 1)
		if l.kind != .instruction && l.kind != .label_and_instruction {
			continue
		}
		for op in l.operands {
			if op.kind != .label_ref {
				continue
			}
			name := op.raw.trim_space()
			if name.starts_with('.') {
				continue
			}

			found := eng.get_indexer().index.find(name) or {
				if eng.enabled('D006') {
					diags << Diag{
						code:     'D006'
						severity: .error
						message:  "undefined symbol '${name}'"
						range:    DiagRange{
							line:      i
							col_start: 0
							col_end:   raw.len
						}
					}
				}
				continue
			}

			// D007 — referenced cross-file but not .global
			if found.file != path && found.vis == .local {
				if eng.enabled('D007') && eng.cfg.symbols.warn_missing_global {
					diags << Diag{
						code:     'D007'
						severity: .warning
						message:  "symbol '${name}' is defined in '${found.file}' but not declared .global"
						range:    DiagRange{
							line:      i
							col_start: 0
							col_end:   raw.len
						}
					}
				}
			}
		}
	}

// D014 dead exports — requires cross-file reference tracking (TODO)

// D008 duplicate symbols
	for name, _ in globals {
		syms := eng.get_indexer().index.find_all(name)
		if syms.len > 1 && eng.enabled('D008') {
			files := syms.map(it.file).join("' and '")
			for sym in syms {
				if sym.file != path {
					continue
				}
				diags << Diag{
					code:     'D008'
					severity: .error
					message:  "duplicate symbol '${name}': defined in '${files}'"
					range:    DiagRange{
						line:      sym.line_nr - 1
						col_start: 0
						col_end:   0
					}
				}
			}
		}
	}

	return diags
}

// ─── helpers ──────────────────────────────────────────────────────────────────

fn (eng &DiagEngine) enabled(code string) bool {
	return !eng.cfg.is_suppressed(code)
}

fn (eng &DiagEngine) make(l Line, raw string, code string, sev DiagSeverity, msg string) Diag {
	// promote to error if configured
	actual_sev := if sev == .warning && eng.cfg.is_error(code, 'warning') {
		DiagSeverity.error
	} else {
		sev
	}
	return Diag{
		code:     code
		severity: actual_sev
		message:  msg
		range:    DiagRange{
			line:      l.line_nr - 1
			col_start: 0
			col_end:   raw.len
		}
	}
}

fn diag_to_json(d Diag) string {
	r := d.range
	parts := [
		'{"range":{"start":{"line":' + r.line.str() + ',"character":' + r.col_start.str() + '},',
		'"end":{"line":' + r.line.str() + ',"character":' + r.col_end.str() + '}},',
		'"severity":' + int(d.severity).str() + ',',
		'"code":"' + d.code + '",',
		'"source":"gaslsp",',
		'"message":"' + d.message + '"}'
	]
	return parts.join('')
}




fn suffix_for_width(bits int) string {
	return match bits {
		8 { 'b' }
		16 { 'w' }
		32 { 'l' }
		64 { 'q' }
		else { '?' }
	}
}

fn suffix_width(s u8) int {
	return match s {
		`b` { 8 }
		`w` { 16 }
		`l` { 32 }
		`q` { 64 }
		else { 0 }
	}
}

fn max_unsigned(bits int) u64 {
	if bits >= 64 {
		return u64(-1)
	}
	return (u64(1) << bits) - 1
}

fn min_signed(bits int) i64 {
	if bits >= 64 {
		return i64(-9223372036854775808)
	}
	return -(i64(1) << (bits - 1))
}

fn max_signed(bits int) i64 {
	if bits >= 64 {
		return i64(9223372036854775807)
	}
	return (i64(1) << (bits - 1)) - 1
}

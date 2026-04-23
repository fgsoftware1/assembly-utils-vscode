// parser.v
// GAS AT&T assembly line parser
// Parses one line at a time into a Line struct

module main

pub enum LineKind {
	empty
	comment
	label
	directive
	instruction
	label_and_instruction // "foo: movq %rax, %rbx"
}

pub struct Operand {
pub:
	raw   string // raw text as written
	kind  OperandKind
	reg   string // register name if kind == .register
	imm   i64    // immediate value if kind == .immediate
	width int    // inferred width in bits (0 = unknown)
}

pub enum OperandKind {
	unknown
	register  // %rax
	immediate // $42
	memory    // (%rax), 8(%rbp), symbol(%rip)
	label_ref // bare symbol (jump target)
}

pub struct Line {
pub:
	kind      LineKind
	label     string // defined label if any (without colon)
	mnemonic  string // instruction mnemonic, lowercased, no suffix
	suffix    u8     // 'b' 'w' 'l' 'q' or 0
	operands  []Operand
	directive string // directive name e.g. "global", "section"
	dir_args  string // raw directive arguments
	raw       string // original line text
	line_nr   int
}

// ─── public entry point ───────────────────────────────────────────────────────

pub fn parse_line(raw string, line_nr int) Line {
	stripped := strip_comment(raw).trim_space()

	if stripped.len == 0 || raw.trim_space().starts_with('#') || raw.trim_space().starts_with('//') {
		return Line{
			kind:    .empty
			raw:     raw
			line_nr: line_nr
		}
	}

	// directive
	if stripped.starts_with('.') {
		return parse_directive(stripped, raw, line_nr)
	}

	// may have a label prefix: "foo:" or "foo: movq ..."
	mut rest := stripped
	mut label := ''
	if colon := find_label_colon(stripped) {
		label = stripped[..colon].trim_space()
		rest = stripped[colon + 1..].trim_space()
	}

	if rest.len == 0 {
		return Line{
			kind:    .label
			label:   label
			raw:     raw
			line_nr: line_nr
		}
	}

	// directive after label (rare but valid)
	if rest.starts_with('.') {
		mut d := parse_directive(rest, raw, line_nr)
		// can't do struct update with mut field, so rebuild
		return Line{
			kind:      .directive
			label:     label
			directive: d.directive
			dir_args:  d.dir_args
			raw:       raw
			line_nr:   line_nr
		}
	}

	// instruction
	instr := parse_instruction(rest, raw, line_nr)
	if label.len > 0 {
		return Line{
			kind:     .label_and_instruction
			label:    label
			mnemonic: instr.mnemonic
			suffix:   instr.suffix
			operands: instr.operands
			raw:      raw
			line_nr:  line_nr
		}
	}
	return instr
}

// ─── directive ────────────────────────────────────────────────────────────────

fn parse_directive(s string, raw string, line_nr int) Line {
	// ".global foo"  → directive="global"  dir_args="foo"
	rest := s[1..] // strip leading dot
	sp := rest.index(' ') or { rest.index('\t') or { -1 } }
	mut name := ''
	mut args := ''
	if sp == -1 {
		name = rest.trim_space()
	} else {
		name = rest[..sp].trim_space()
		args = rest[sp + 1..].trim_space()
	}
	return Line{
		kind:      .directive
		directive: name.to_lower()
		dir_args:  args
		raw:       raw
		line_nr:   line_nr
	}
}

// ─── instruction ─────────────────────────────────────────────────────────────

fn parse_instruction(s string, raw string, line_nr int) Line {
	// split mnemonic from operands
	sp := first_whitespace(s)
	mut mnem_raw := ''
	mut ops_raw := ''
	if sp == -1 {
		mnem_raw = s
	} else {
		mnem_raw = s[..sp]
		ops_raw = s[sp + 1..].trim_space()
	}

	mnem_lower := mnem_raw.to_lower()
	mnemonic, suffix := split_suffix(mnem_lower)
	operands := if ops_raw.len > 0 { parse_operands(ops_raw) } else { []Operand{} }

	return Line{
		kind:     .instruction
		mnemonic: mnemonic
		suffix:   suffix
		operands: operands
		raw:      raw
		line_nr:  line_nr
	}
}

// split "movq" → ("mov", `q`),  "mov" → ("mov", 0)
fn split_suffix(mnem string) (string, u8) {
	if mnem.len == 0 {
		return '', 0
	}
	last := mnem[mnem.len - 1]
	// only split if the base without suffix is a known-style mnemonic
	// conservative: only strip if last char is a known suffix
	if last == `b` || last == `w` || last == `l` || last == `q` {
		// don't strip from mnemonics that end in those letters naturally
		// e.g. "call", "cmpxchg", "push", "mul", "jl", "jnl", "jg", etc.
		nosuf := mnem[..mnem.len - 1]
		if is_suffixable(nosuf) {
			return nosuf, last
		}
	}
	return mnem, 0
}

// mnemonics that accept size suffixes — checked after stripping last char
fn is_suffixable(base string) bool {
	return base in [
		'mov',
		'movs',
		'movz',
		'push',
		'pop',
		'add',
		'sub',
		'and',
		'or',
		'xor',
		'not',
		'neg',
		'inc',
		'dec',
		'mul',
		'imul',
		'div',
		'idiv',
		'cmp',
		'test',
		'shl',
		'shr',
		'sar',
		'lea',
		'xchg',
		'cmpxchg',
		'bsf',
		'bsr',
		'bswap',
		'cmov',
		'cmove',
		'cmovne',
		'cmovg',
		'cmovge',
		'cmovl',
		'cmovle',
		'cmova',
		'cmovae',
		'cmovb',
		'cmovbe',
		'set',
		'sete',
		'setne',
		'setg',
		'setge',
		'setl',
		'setle',
		'seta',
		'setae',
		'setb',
		'setbe',
		'sto',
		'lod',
	]
}

// ─── operand parsing ──────────────────────────────────────────────────────────

fn parse_operands(s string) []Operand {
	mut ops := []Operand{}
	// split by comma, but not commas inside parentheses
	parts := split_operands(s)
	for p in parts {
		ops << classify_operand(p.trim_space())
	}
	return ops
}

fn split_operands(s string) []string {
	mut parts := []string{}
	mut depth := 0
	mut start := 0
	for i, c in s {
		if c == `(` {
			depth++
		}
		if c == `)` {
			depth--
		}
		if c == `,` && depth == 0 {
			parts << s[start..i].trim_space()
			start = i + 1
		}
	}
	if start < s.len {
		parts << s[start..].trim_space()
	}
	return parts
}

fn classify_operand(s string) Operand {
	if s.len == 0 {
		return Operand{
			raw:  s
			kind: .unknown
		}
	}

	// register: starts with %
	if s.starts_with('%') {
		reg := s[1..].to_lower()
		w := reg_width(reg)
		return Operand{
			raw:   s
			kind:  .register
			reg:   reg
			width: w
		}
	}

	// immediate: starts with $
	if s.starts_with('$') {
		val_str := s[1..]
		val := parse_imm(val_str)
		return Operand{
			raw:  s
			kind: .immediate
			imm:  val
		}
	}

	// memory: contains ( or is purely numeric offset
	if s.contains('(') || s.contains(')') {
		return Operand{
			raw:  s
			kind: .memory
		}
	}

	// bare symbol / label reference (jump target etc.)
	return Operand{
		raw:  s
		kind: .label_ref
	}
}

fn parse_imm(s string) i64 {
	t := s.trim_space()
	if t.starts_with('0x') || t.starts_with('0X') {
		return i64(t[2..].parse_uint(16, 64) or { 0 })
	}
	if t.starts_with('0b') || t.starts_with('0B') {
		return i64(t[2..].parse_uint(2, 64) or { 0 })
	}
	if t.starts_with('-') {
		return -(t[1..].parse_uint(10, 64) or { 0 }).str().i64()
	}
	return i64(t.parse_uint(10, 64) or { 0 })
}

// return bit width of a register name, 0 if unknown
fn reg_width(name string) int {
	return match name {
		'al', 'ah', 'bl', 'bh', 'cl', 'ch', 'dl', 'dh', 'sil', 'dil', 'spl', 'bpl', 'r8b', 'r9b',
		'r10b', 'r11b', 'r12b', 'r13b', 'r14b', 'r15b' {
			8
		}
		'ax', 'bx', 'cx', 'dx', 'si', 'di', 'sp', 'bp', 'r8w', 'r9w', 'r10w', 'r11w', 'r12w',
		'r13w', 'r14w', 'r15w' {
			16
		}
		'eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'esp', 'ebp', 'r8d', 'r9d', 'r10d', 'r11d',
		'r12d', 'r13d', 'r14d', 'r15d' {
			32
		}
		'rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'rsp', 'rbp', 'rip', 'r8', 'r9', 'r10', 'r11',
		'r12', 'r13', 'r14', 'r15' {
			64
		}
		'xmm0', 'xmm1', 'xmm2', 'xmm3', 'xmm4', 'xmm5', 'xmm6', 'xmm7', 'xmm8', 'xmm9', 'xmm10',
		'xmm11', 'xmm12', 'xmm13', 'xmm14', 'xmm15' {
			128
		}
		'ymm0', 'ymm1', 'ymm2', 'ymm3', 'ymm4', 'ymm5', 'ymm6', 'ymm7', 'ymm8', 'ymm9', 'ymm10',
		'ymm11', 'ymm12', 'ymm13', 'ymm14', 'ymm15' {
			256
		}
		else {
			0
		}
	}
}

// ─── helpers ──────────────────────────────────────────────────────────────────

// strip ; and # comments, respecting quoted strings
fn strip_comment(s string) string {
	mut in_str := false
	for i, c in s {
		if c == `"` {
			in_str = !in_str
		}
		if !in_str && (c == `#` || c == `;`) {
			return s[..i]
		}
	}
	return s
}

// find the colon that ends a label, ignoring colons inside strings/memory operands
fn find_label_colon(s string) ?int {
	for i, c in s {
		if c == `:` {
			return i
		}
		// if we hit whitespace before a colon, no label here
		if c == ` ` || c == `\t` {
			return none
		}
		// directives and instructions don't have labels
		if c == `.` && i == 0 {
			return none
		}
	}
	return none
}

fn first_whitespace(s string) int {
	for i, c in s {
		if c == ` ` || c == `\t` {
			return i
		}
	}
	return -1
}

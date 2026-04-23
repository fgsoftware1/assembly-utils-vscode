module main

import os

pub struct RpcRequest {
pub:
	jsonrpc string
	id      ?int
	method  string
	params  ?string
}

pub fn read_message() ?RpcRequest {
	mut content_length := -1

	for {
		line := read_line() or { break }
		trimmed := line.trim_space()
		if trimmed.len == 0 {
			break
		}
		if trimmed.to_lower().starts_with('content-length:') {
			val := trimmed['content-length:'.len..].trim_space()
			content_length = val.int()
		}
	}

	if content_length <= 0 {
		return none
	}

	mut body := ''
	mut remaining := content_length
	for remaining > 0 {
		chunk, n := os.fd_read(0, remaining)
		if n <= 0 {
			return none
		}
		body += chunk
		remaining -= n
	}

	return parse_request(body)
}

pub fn send_response(id ?int, result string) {
	write_message("{\"jsonrpc\":\"2.0\",\"id\":${id_str(id)},\"result\":${result}}")
}

pub fn send_error(id ?int, code int, message string) {
	msg := message.replace('"', '\\"')
	write_message("{\"jsonrpc\":\"2.0\",\"id\":${id_str(id)},\"error\":{\"code\":${code},\"message\":\"${msg}\"}}")
}

pub fn send_notification(method string, params string) {
	write_message("{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params}}")
}

fn write_message(body string) {
	os.fd_write(1, "Content-Length: ${body.len}\r\n\r\n")
	os.fd_write(1, body)
}

fn read_line() ?string {
	mut line := []u8{}
	for {
		data, n := os.fd_read(0, 1)
		if n <= 0 {
			return none
		}
		b := data[0]
		if b == `\n` {
			break
		}
		if b != `\r` {
			line << b
		}
	}
	return line.bytestr()
}

pub fn id_str(id ?int) string {
	return if v := id { v.str() } else { 'null' }
}

fn parse_request(body string) ?RpcRequest {
	method := json_str_field(body, 'method') or { return none }
	id := json_int_field(body, 'id')
	params := json_raw_field(body, 'params')
	return RpcRequest{
		jsonrpc: '2.0'
		id:      id
		method:  method
		params:  params
	}
}

pub fn json_str_field(s string, key string) ?string {
	needle := '"${key}":'
	idx := s.index(needle) or { return none }
	rest := s[idx + needle.len..].trim_space()
	if !rest.starts_with('"') {
		return none
	}
	mut i := 1
	for i < rest.len {
		if rest[i] == `\\` {
			i += 2
			continue
		}
		if rest[i] == `"` {
			return rest[1..i]
		}
		i++
	}
	return none
}

pub fn json_int_field(s string, key string) ?int {
	needle := '"${key}":'
	idx := s.index(needle) or { return none }
	rest := s[idx + needle.len..].trim_space()
	if rest.starts_with('null') {
		return none
	}
	mut i := 0
	for i < rest.len && (rest[i].is_digit() || (i == 0 && rest[i] == `-`)) {
		i++
	}
	if i == 0 {
		return none
	}
	return rest[..i].int()
}

pub fn json_raw_field(s string, key string) ?string {
	needle := '"${key}":'
	idx := s.index(needle) or { return none }
	rest := s[idx + needle.len..].trim_space()
	if rest.len == 0 {
		return none
	}
	return extract_raw_value(rest)
}

fn extract_raw_value(s string) ?string {
	if s.len == 0 {
		return none
	}
	ch := s[0]
	if ch == `{` || ch == `[` {
		close := if ch == `{` { `}` } else { `]` }
		mut depth := 0
		mut in_str := false
		for i, c in s {
			if in_str {
				if c == `\\` {
					continue
				}
				if c == `"` {
					in_str = false
				}
				continue
			}
			if c == `"` {
				in_str = true
				continue
			}
			if c == ch {
				depth++
			}
			if c == close {
				depth--
				if depth == 0 {
					return s[..i + 1]
				}
			}
		}
		return none
	}
	if ch == `"` {
		mut i := 1
		for i < s.len {
			if s[i] == `\\` {
				i += 2
				continue
			}
			if s[i] == `"` {
				return s[..i + 1]
			}
			i++
		}
		return none
	}
	mut i := 0
	for i < s.len && s[i] != `,` && s[i] != `}` && s[i] != `]` {
		i++
	}
	return s[..i].trim_space()
}

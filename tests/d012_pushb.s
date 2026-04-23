# Test: pushb not encodable should trigger D012
# This is a comment
.section .text
.global _start
_start:
    pushb $42
    ret

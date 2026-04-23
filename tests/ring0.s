# Test MSR and other ring-0 instructions
.section .text
.global _start
_start:
    # These require ring 0 - will fail in user mode
    # rdmsr
    # wrmsr
    
    # Wait and iret
    iretq
    
    nop
    ret

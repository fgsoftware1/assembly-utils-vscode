# Test all new opcodes
.section .data
gdt_desc:
    .word 0x10      # limit
    .quad 0        # base

.section .text
.global _start
_start:
    # Test new instructions
    lgdt gdt_desc
    lidt gdt_desc
    ltr %ax
    sgdt gdt_desc
    sidt gdt_desc
    str %ax
    
    rdtsc
    rdtscp
    
    # Control reg (ring 0 only, won't assemble)
    # movq %cr0, %rax
    
    # Debug reg
    # movq %dr0, %rax
    
    # Cache stuff (ring 0 only)
    # invlpg (%rax)
    # invd
    # wbinvd
    
    nop
    ret

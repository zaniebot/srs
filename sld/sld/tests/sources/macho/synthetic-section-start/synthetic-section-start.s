//#Object:runtime.c
//#ExpectSym:__start___custom section="__custom"
//#RunEnabled:true
//#SkipLinker:apple-ld

.section __TEXT,__text,regular,pure_instructions
.globl _main
.p2align 2
_main:
    adrp x9, __start___custom@PAGE
    add x9, x9, __start___custom@PAGEOFF
    mov w0, #42
    b _exit_syscall

.section __TEXT,__custom,regular,pure_instructions
.p2align 2
_custom_instruction:
    ret

//#Object:runtime.c
//#LinkArgs:-dead_strip
//#ExpectSym:_main section="__text",offset-in-section=0
//#ExpectSym:_live_ptr section="__const"
//#ExpectSym:_live_ptr_two section="__const"
//#ExpectSym:_live_target section="__text"
//#ExpectSym:_live_target_two section="__text"
//#NoSym:_dead_target
//#RunEnabled:true

.subsections_via_symbols

.section __TEXT,__text
.p2align 2
.globl _main
_main:
    adrp x9, _live_ptr@PAGE
    add x9, x9, _live_ptr@PAGEOFF
    adrp x10, _live_ptr_two@PAGE
    add x10, x10, _live_ptr_two@PAGEOFF
    mov w0, #42
    b _exit_syscall

.p2align 2
.globl _live_target
_live_target:
    ret

.p2align 2
.globl _live_target_two
_live_target_two:
    ret

.p2align 2
.globl _dead_target
_dead_target:
    ret

.section __DATA,__const
.p2align 3
.globl _live_ptr
_live_ptr:
    .quad _live_target

.p2align 3
.globl _live_ptr_two
_live_ptr_two:
    .quad _live_target_two

.p2align 3
.globl _dead_ptr
_dead_ptr:
    .quad _dead_target

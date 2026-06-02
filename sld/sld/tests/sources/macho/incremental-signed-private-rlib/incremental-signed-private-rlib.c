//#Config:incremental-signed-private-rlib
//#Object:runtime.c
//#Rlib:incremental-signed-private-rlib-value.rs
//#RunEnabled:true
//#DiffEnabled:false
//#TestIncremental:true
//#TestIncrementalPrivateSignedMachOOutput:true
//#TestIncrementalChanged:true
//#TestIncrementalChangedImmediately:true
//#TestIncrementalChangedInput:incremental-signed-private-rlib-value.rs.rlib
//#TestIncrementalChangedSection:__data
//#TestIncrementalChangedRun:true
//#TestIncrementalChangedSymbolBytes:_incremental_signed_private_rlib_value=0x2b000000

#include "../common/runtime.h"

extern int incremental_signed_private_rlib_value;

void main(void) {
  int value = incremental_signed_private_rlib_value;
  exit_syscall(value == 43 ? 42 : 1);
}

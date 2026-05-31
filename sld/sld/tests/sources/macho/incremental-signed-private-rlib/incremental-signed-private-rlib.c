//#Config:incremental-signed-private-rlib
//#Object:runtime.c
//#Rlib:incremental-signed-private-rlib-value.rs
//#RunEnabled:true
//#DiffEnabled:false
//#TestIncremental:true
//#TestIncrementalPrivateSignedMachOOutput:true
//#TestIncrementalChanged:true
//#TestIncrementalChangedInput:incremental-signed-private-rlib-value.rs.rlib
//#TestIncrementalChangedSection:__data
//#TestIncrementalChangedRun:true

#include "../common/runtime.h"

extern int incremental_signed_private_rlib_value;

void main(void) {
  int value = incremental_signed_private_rlib_value;
  exit_syscall(value == 42 || value == 43 ? 42 : 1);
}

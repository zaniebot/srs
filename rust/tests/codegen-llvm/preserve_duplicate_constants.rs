//@ compile-flags: -Zcodegen-backend=llvm
//@ revisions: DEDUP PRESERVE OPT_PRESERVE
//@ [DEDUP] compile-flags: -C no-prepopulate-passes
//@ [PRESERVE] compile-flags: -C no-prepopulate-passes -Zpreserve-duplicate-constants=yes
//@ [OPT_PRESERVE] compile-flags: -O -Zpreserve-duplicate-constants=yes

#![crate_type = "lib"]

// DEDUP: @FIRST = {{.*}} ptr [[DEDUP_ALLOC:@alloc_[a-f0-9]+]]
// DEDUP: @SECOND = {{.*}} ptr [[DEDUP_ALLOC]]
// DEDUP: [[DEDUP_ALLOC]] = private unnamed_addr constant [4 x i8] c"foo\00"
//
// PRESERVE: @FIRST = {{.*}} ptr [[FIRST_ALLOC:@alloc_[a-f0-9.]+]]
// PRESERVE-NOT: @SECOND = {{.*}} ptr [[FIRST_ALLOC]]
// PRESERVE: @SECOND = {{.*}} ptr [[SECOND_ALLOC:@alloc_[a-f0-9.]+]]
// PRESERVE: [[FIRST_ALLOC]] = private constant [4 x i8] c"foo\00"
// PRESERVE: [[SECOND_ALLOC]] = private constant [4 x i8] c"foo\00"
//
// OPT_PRESERVE: @FIRST = {{.*}} ptr [[OPT_FIRST_ALLOC:@alloc_[a-f0-9.]+]]
// OPT_PRESERVE-NOT: @SECOND = {{.*}} ptr [[OPT_FIRST_ALLOC]]
// OPT_PRESERVE: @SECOND = {{.*}} ptr [[OPT_SECOND_ALLOC:@alloc_[a-f0-9.]+]]
// OPT_PRESERVE: [[OPT_FIRST_ALLOC]] = private constant [4 x i8] c"foo\00"
// OPT_PRESERVE: [[OPT_SECOND_ALLOC]] = private constant [4 x i8] c"foo\00"
#[no_mangle]
pub static FIRST: &[u8; 4] = b"foo\0";

#[no_mangle]
pub static SECOND: &[u8; 4] = b"foo\0";

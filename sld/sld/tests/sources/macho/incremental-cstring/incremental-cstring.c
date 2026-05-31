//#AbstractConfig:incremental-cstring-base
//#Object:incremental-cstring-value.s
//#RunEnabled:false
//#DiffEnabled:false
//#TestIncremental:true
//#TestIncrementalUnsignedMachOOutput:true
//#TestIncrementalChanged:true
//#TestIncrementalChangedInput:incremental-cstring-value.s.o
//#TestIncrementalChangedSection:__cstring
//#Config:stable-boundary:incremental-cstring-base
//#TestIncrementalChangedImmediately:true
//#TestIncrementalChangedExpectPatch:true
//#Config:moved-boundary:incremental-cstring-base
//#TestIncrementalChangedSectionOffset:6
//#TestIncrementalChangedExpectPatch:false
//#TestIncrementalChangedFallbackReason:changed Mach-O cstring literal boundaries

extern const char incremental_cstring_value[];

int main(void) { return incremental_cstring_value[0]; }

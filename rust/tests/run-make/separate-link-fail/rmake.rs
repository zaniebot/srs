// rustc usually wants Rust code as its input. The flag `link-only` is one
// exception, where a .rlink file is instead requested. The compiler should
// fail when the user is wrongly passing the original Rust code
// instead of the generated .rlink file when this flag is on.
// https://github.com/rust-lang/rust/issues/95297

use run_make_support::{rfs, rustc};

fn main() {
    rustc()
        .arg("-Zlink-only")
        .input("foo.rs")
        .run_fail()
        .assert_stderr_contains("the input does not look like a .rlink file");

    // Older .rlink schemas must also fail cleanly.
    const PREVIOUS_RLINK_VERSION: u32 = 1;
    rustc().arg("-Zno-link").input("foo.rs").run();
    let mut rlink = rfs::read("foo.rlink");
    let version_start = b"rustlink".len();
    rlink[version_start..version_start + 4].copy_from_slice(&PREVIOUS_RLINK_VERSION.to_be_bytes());
    rfs::write("foo.rlink", rlink);
    rustc()
        .arg("-Zlink-only")
        .input("foo.rlink")
        .run_fail()
        .assert_stderr_contains("but the current version is `2`");
}

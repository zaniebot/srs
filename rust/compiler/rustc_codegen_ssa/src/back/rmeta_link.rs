//! Late-metadata archive member that lists which rlib entries are Rust object files,
//! and potentially other data collected and used when building or linking a rlib.
//! See <https://github.com/rust-lang/rust/issues/138243>.

use std::path::Path;

use object::read::archive::ArchiveFile;
use rustc_serialize::opaque::mem_encoder::MemEncoder;
use rustc_serialize::opaque::{MAGIC_END_BYTES, MemDecoder};
use rustc_serialize::{Decodable, Encodable};
use rustc_span::{SourceFileHash, SourceFileHashAlgorithm};

use super::metadata::search_for_section;

pub(crate) const FILENAME: &str = "lib.rmeta-link";
pub(crate) const SECTION: &str = ".rmeta-link";
const LINK_CONTENT_DIGEST_PREFIX: &[u8] = b"rustc-rlib-link-content-v1:";
const BLAKE3_HEX_DIGEST_LEN: usize = 64;

pub struct RmetaLink {
    pub rust_object_files: Vec<String>,
    pub link_content_digest: Option<String>,
}

impl RmetaLink {
    pub(crate) fn encode(&self) -> Vec<u8> {
        let mut encoder = MemEncoder::new();
        self.rust_object_files.encode(&mut encoder);
        let mut data = encoder.finish();
        if let Some(digest) =
            self.link_content_digest.as_deref().filter(|digest| is_blake3_hex_digest(digest))
        {
            data.extend_from_slice(LINK_CONTENT_DIGEST_PREFIX);
            data.extend_from_slice(digest.as_bytes());
        }
        data.extend_from_slice(MAGIC_END_BYTES);
        data
    }

    pub(crate) fn decode(data: &[u8]) -> Option<RmetaLink> {
        let mut decoder = MemDecoder::new(data, 0).ok()?;
        let rust_object_files = Vec::<String>::decode(&mut decoder);
        let link_content_digest = decode_link_content_digest(data);
        Some(RmetaLink { rust_object_files, link_content_digest })
    }
}

pub(crate) fn link_content_digest<'a>(
    objects: impl IntoIterator<Item = (&'a str, &'a str)>,
) -> Option<String> {
    let objects = objects.into_iter().collect::<Vec<_>>();
    if objects.iter().any(|(_, digest)| !is_blake3_hex_digest(digest)) {
        return None;
    }
    let mut contents = Vec::new();
    contents.extend_from_slice(b"rustc-rlib-link-content-v1");
    contents.extend_from_slice(&(objects.len() as u64).to_le_bytes());
    for (name, digest) in objects {
        contents.extend_from_slice(&(name.len() as u64).to_le_bytes());
        contents.extend_from_slice(name.as_bytes());
        contents.extend_from_slice(digest.as_bytes());
    }

    Some(render_blake3_digest(SourceFileHash::new_in_memory(
        SourceFileHashAlgorithm::Blake3,
        contents,
    )))
}

fn decode_link_content_digest(data: &[u8]) -> Option<String> {
    let data = data.strip_suffix(MAGIC_END_BYTES)?;
    let suffix_len = LINK_CONTENT_DIGEST_PREFIX.len() + BLAKE3_HEX_DIGEST_LEN;
    let suffix = data.get(data.len().checked_sub(suffix_len)?..)?;
    let digest = suffix.strip_prefix(LINK_CONTENT_DIGEST_PREFIX)?;
    let digest = std::str::from_utf8(digest).ok()?;
    is_blake3_hex_digest(digest).then(|| digest.to_owned())
}

fn is_blake3_hex_digest(digest: &str) -> bool {
    digest.len() == BLAKE3_HEX_DIGEST_LEN
        && digest.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn render_blake3_digest(digest: SourceFileHash) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";

    let mut rendered = String::with_capacity(BLAKE3_HEX_DIGEST_LEN);
    for byte in digest.hash_bytes() {
        rendered.push(HEX[(byte >> 4) as usize] as char);
        rendered.push(HEX[(byte & 0xf) as usize] as char);
    }
    rendered
}

/// Reads the link-time metadata from an already-parsed archive.
pub fn read(archive: &ArchiveFile<'_>, archive_data: &[u8], rlib_path: &Path) -> Option<RmetaLink> {
    for entry in archive.members() {
        let entry = entry.ok()?;
        if entry.name() == FILENAME.as_bytes() {
            let data = entry.data(archive_data).ok()?;
            let section_data = search_for_section(rlib_path, data, SECTION).ok()?;
            return RmetaLink::decode(section_data);
        }
    }
    None
}

/// Like [`read`], but parses the archive from raw bytes.
///
/// Use this when the caller's `ArchiveFile` comes from a different version of the `object` crate.
pub fn read_from_data(archive_data: &[u8], rlib_path: &Path) -> Option<RmetaLink> {
    let archive = ArchiveFile::parse(archive_data).ok()?;
    read(&archive, archive_data, rlib_path)
}

#[cfg(test)]
mod tests {
    use rustc_serialize::Encodable;
    use rustc_serialize::opaque::MAGIC_END_BYTES;
    use rustc_serialize::opaque::mem_encoder::MemEncoder;

    use super::{RmetaLink, link_content_digest};

    #[test]
    fn rmeta_link_decodes_legacy_metadata_without_link_content_digest() {
        let rust_object_files = vec!["crate.cgu.rcgu.o".to_owned()];
        let mut encoder = MemEncoder::new();
        rust_object_files.encode(&mut encoder);
        let mut data = encoder.finish();
        data.extend_from_slice(MAGIC_END_BYTES);

        let decoded = RmetaLink::decode(&data).unwrap();

        assert_eq!(decoded.rust_object_files, rust_object_files);
        assert_eq!(decoded.link_content_digest, None);
    }

    #[test]
    fn rmeta_link_round_trips_link_content_digest() {
        let digest = link_content_digest([
            ("crate.cgu.1", "a".repeat(64).as_str()),
            ("crate.cgu.0", "b".repeat(64).as_str()),
        ])
        .unwrap();
        let metadata = RmetaLink {
            rust_object_files: vec!["crate.cgu.rcgu.o".to_owned()],
            link_content_digest: Some(digest.clone()),
        };

        let decoded = RmetaLink::decode(&metadata.encode()).unwrap();

        assert_eq!(decoded.rust_object_files, metadata.rust_object_files);
        assert_eq!(decoded.link_content_digest, Some(digest));
    }

    #[test]
    fn link_content_digest_preserves_object_order_and_requires_object_digests() {
        let first = link_content_digest([
            ("crate.cgu.1", "a".repeat(64).as_str()),
            ("crate.cgu.0", "b".repeat(64).as_str()),
        ]);
        let reordered = link_content_digest([
            ("crate.cgu.0", "b".repeat(64).as_str()),
            ("crate.cgu.1", "a".repeat(64).as_str()),
        ]);

        assert_ne!(first, reordered);
        assert_eq!(link_content_digest([("crate.cgu.0", "invalid")]), None);
    }
}

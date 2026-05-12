//! Arch Linux distribution detection helpers.
//!
//! Used to suppress Fedora/RPM-specific security checks (SELinux, rpm -V)
//! that produce false-positive alerts on Arch-based systems (CachyOS, plain Arch).

use std::path::Path;

/// Returns `true` when the host is an Arch-based distribution (CachyOS, Arch Linux, etc.).
///
/// Detection is based on the presence of `/etc/arch-release`, which is a standard
/// Arch Linux marker file installed by the `filesystem` package on every Arch variant.
pub fn is_arch_based() -> bool {
    is_arch_based_at(Path::new("/etc/arch-release"))
}

/// Inner helper — accepts a custom path so unit tests can inject a temp file.
pub(crate) fn is_arch_based_at(path: &Path) -> bool {
    path.exists()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    #[test]
    fn test_is_arch_based_when_file_present() {
        let tmp = NamedTempFile::new().expect("could not create temp file");
        assert!(is_arch_based_at(tmp.path()));
    }

    #[test]
    fn test_is_arch_based_when_file_absent() {
        let absent = Path::new("/tmp/nonexistent-arch-release-test-lifeos");
        assert!(!is_arch_based_at(absent));
    }
}

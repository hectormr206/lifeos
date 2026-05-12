//! Arch Linux distribution detection helpers.
//!
//! Used to suppress Fedora/RPM-specific security checks (SELinux, rpm -V)
//! that produce false-positive alerts on Arch-based systems (CachyOS, plain Arch).

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::NamedTempFile;

    #[test]
    fn test_is_arch_based_when_file_present() {
        // The function checks /etc/arch-release existence.
        // We test the inner logic by passing a custom path.
        let tmp = NamedTempFile::new().expect("could not create temp file");
        assert!(is_arch_based_at(tmp.path()));
    }

    #[test]
    fn test_is_arch_based_when_file_absent() {
        let absent = std::path::Path::new("/tmp/nonexistent-arch-release-test-lifeos");
        assert!(!is_arch_based_at(absent));
    }
}

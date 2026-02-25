# LifeOS Testing Guide

## Overview

This guide covers how to run tests, write new tests, and follow test conventions for the LifeOS project.

## Quick Start

### Running All Tests

```bash
# Run all tests
make test

# Or manually:
cd cli && cargo test --all-features
cd daemon && cargo test --all-features
```

### Running Specific Test Suites

```bash
# CLI tests only
make test-cli

# Daemon tests only
make test-daemon

# Integration tests
make test-integration
```

### Running Tests with Coverage

```bash
# Generate HTML coverage report
make test-coverage

# Or manually:
cd cli && cargo tarpaulin --out Html --output-dir ./coverage
cd daemon && cargo tarpaulin --out Html --output-dir ./coverage
```

## Test Structure

### Unit Tests

Unit tests are located within source files using `#[cfg(test)]` modules:

```rust
// src/my_module.rs
pub fn my_function() -> i32 {
    42
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_my_function() {
        assert_eq!(my_function(), 42);
    }
}
```

Or in separate test files:

```rust
// src/my_module_tests.rs
#[cfg(test)]
mod tests {
    use crate::my_module::*;

    #[test]
    fn test_my_function() {
        assert_eq!(my_function(), 42);
    }
}
```

### Integration Tests

Integration tests are in the `tests/integration/` directory:

```rust
// tests/integration/main.rs
#[test]
fn test_cli_daemon_integration() {
    // Test code here
}
```

### Test Organization

```
lifeos/
├── cli/src/
│   ├── config/
│   │   ├── mod.rs
│   │   └── tests.rs      # Unit tests for config module
│   ├── system/
│   │   ├── mod.rs
│   │   └── tests.rs      # Unit tests for system module
│   └── main_tests.rs     # CLI argument parsing tests
├── daemon/src/
│   ├── health.rs
│   ├── health_tests.rs   # Health monitoring tests
│   ├── updates.rs
│   └── updates_tests.rs  # Update checker tests
└── tests/
    ├── Cargo.toml
    └── integration/
        └── main.rs       # Integration tests
```

## Writing Tests

### Test Conventions

1. **Naming**: Use descriptive names prefixed with `test_`:
   ```rust
   #[test]
   fn test_config_loads_valid_file() { }
   ```

2. **Assertions**: Use specific assertions:
   ```rust
   assert_eq!(actual, expected);
   assert!(condition);
   assert!(result.is_ok());
   assert!(result.is_err());
   ```

3. **Async Tests**: Use `#[tokio::test]` for async tests:
   ```rust
   #[tokio::test]
   async fn test_async_operation() {
       let result = async_function().await;
       assert!(result.is_ok());
   }
   ```

4. **Test Data**: Use `tempfile` for temporary files:
   ```rust
   use tempfile::NamedTempFile;
   use std::io::Write;

   #[test]
   fn test_file_operations() {
       let mut file = NamedTempFile::new().unwrap();
       file.write_all(b"test data").unwrap();
       // Test with file
   }
   ```

### Mocking External Dependencies

Use `mockall` for mocking:

```rust
use mockall::automock;

#[automock]
trait MyTrait {
    fn do_something(&self) -> i32;
}

#[test]
fn test_with_mock() {
    let mut mock = MockMyTrait::new();
    mock.expect_do_something()
        .returning(|| 42);
    
    assert_eq!(mock.do_something(), 42);
}
```

### Testing CLI Commands

```rust
use clap::Parser;

#[test]
fn test_cli_parses_init_command() {
    let cli = Cli::parse_from(["life", "init"]);
    match cli.command {
        Commands::Init(_) => (), // Pass
        _ => panic!("Expected Init command"),
    }
}
```

### Testing Configuration

```rust
#[test]
fn test_config_roundtrip() {
    let config = LifeConfig::default();
    let toml_str = toml::to_string_pretty(&config).unwrap();
    let parsed: LifeConfig = toml::from_str(&toml_str).unwrap();
    assert_eq!(config.version, parsed.version);
}
```

## Test Fixtures

Place test fixtures in `tests/fixtures/`:

```
tests/
├── fixtures/
│   ├── valid_config.toml
│   ├── invalid_config.toml
│   └── sample_output.json
└── integration/
    └── main.rs
```

Load fixtures in tests:

```rust
use std::fs;

#[test]
fn test_with_fixture() {
    let content = fs::read_to_string("tests/fixtures/valid_config.toml")
        .expect("Failed to read fixture");
    let config: LifeConfig = toml::from_str(&content).unwrap();
    assert_eq!(config.version, "1");
}
```

## Environment-Specific Tests

Skip tests when dependencies aren't available:

```rust
#[test]
fn test_bootc_integration() {
    if !is_bootc_available() {
        println!("Skipping test: bootc not available");
        return;
    }
    // Test code
}
```

Or use conditional compilation:

```rust
#[cfg(target_os = "linux")]
#[test]
fn test_linux_specific_feature() {
    // Linux-only test
}
```

## Continuous Integration

Tests run automatically on:
- Every Pull Request
- Every push to `main` or `develop`
- Weekly scheduled builds

CI runs:
1. Unit tests (`cargo test`)
2. Integration tests
3. Code coverage (tarpaulin)
4. Security audit (cargo audit)

## Debugging Tests

### Verbose Output

```bash
# Show all test output
cargo test -- --nocapture

# Show output for specific test
cargo test test_name -- --nocapture
```

### Running Single Test

```bash
cargo test test_config_loads_valid_file
```

### Debugging with Logs

```rust
#[test]
fn test_with_logging() {
    env_logger::init();
    log::debug!("Debug information: {:?}", value);
    // Test code
}
```

## Test Coverage Goals

| Component | Target Coverage |
|-----------|-----------------|
| Config    | 90%             |
| CLI       | 80%             |
| Daemon    | 75%             |
| System    | 70%             |

View coverage report:

```bash
# Generate HTML report
cargo tarpaulin --out Html

# Open report
open coverage/tarpaulin-report.html
```

## Best Practices

1. **Isolate Tests**: Each test should be independent
2. **Fast Tests**: Keep tests fast (avoid sleeps, use timeouts)
3. **Deterministic**: Tests should produce the same results every time
4. **Clean Up**: Use `tempfile` and RAII for cleanup
5. **Document**: Add comments explaining complex test scenarios

## Troubleshooting

### Tests Fail in CI but Pass Locally

- Check for environment differences
- Ensure all dependencies are installed
- Use containerized tests for consistency

### Flaky Tests

- Add retry logic for external dependencies
- Use deterministic test data
- Increase timeouts for slow operations

### Permission Errors

```bash
# Ensure test binaries are executable
chmod +x target/debug/deps/*
```

## Contributing New Tests

When adding features:

1. Write tests first (TDD approach)
2. Add unit tests for new functions
3. Add integration tests for user workflows
4. Update this documentation if needed
5. Ensure CI passes before submitting PR

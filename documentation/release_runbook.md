# PSUB Release Runbook

This runbook captures the repeatable workflow for building CPython security releases from source on Windows with PSUB.

## Scope

- Supported release lines: `3.10.x`, `3.11.x`, `3.12.x`
- Build source from python.org artifacts (no prebuilt binaries)

## Standard flow

1. Identify latest patch release for target minor line on python.org.
2. Download source archive and signature into `C:\src\Python-<version>\`.
3. Verify integrity using official metadata/signatures.
4. Extract source to `C:\src\Python-<version>\Python-<version>`.
5. Validate required folders:
- `PCbuild`
- `Tools\msi`
- `Doc\requirements.txt`
6. Run PSUB build script:
`.\Script\Build-PythonRelease.ps1 -SourcePath "C:\src\Python-<version>\Python-<version>"`
7. Validate artifacts and archive evidence.

## Preflight checks

- Git available: `git --version`
- Bootstrap Python available: 3.10 or 3.12
- Visual Studio 2019 C++ workload/toolchains installed
- Windows SDK available (10.0.19041.0 or later)

## Known issues and fixes

### 1) Python 3.10 MSI WiX `MSB4062`

- Error indicates legacy WiX/MSBuild dependency missing.
- Ensure `Tools\msi\get_externals.bat` was run.
- Ensure .NET 3.5 components required by the WiX toolchain are available.

### 2) `buildrelease.bat` false success exit code

- A build can print `Build FAILED.` while process returns `0`.
- PSUB script has an output-based failure guard in step 4 to stop early.

### 3) SDK registry path mismatch

- Some environments expose SDK under WOW6432Node registry path.
- Verify both registry and include directory on disk.

## Evidence to keep

- Source version and source URLs
- Integrity verification results
- Build command and `SourcePath`
- Build log path
- Artifact output path and zip path
- Any warnings/errors and final disposition

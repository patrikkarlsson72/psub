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

- Git available: `git --version` (recommended, not required)
- Bootstrap Python available: 3.10 or 3.12
- Visual Studio 2022 Professional (recommended) or Visual Studio 2019 with C++ workload/toolchains installed
- Windows SDK available (10.0.19041.0 or later)
- Record the actual SDK version used if PSUB falls forward to a newer installed version

If the source tree comes from an extracted `python.org` archive rather than a Git checkout, Git-related warnings from CPython build steps can be expected and are not automatically build failures.

## Known issues and fixes

### 1) Python 3.10 MSI WiX `MSB4062`

- Error indicates legacy WiX/MSBuild dependency missing.
- Ensure `Tools\msi\get_externals.bat` was run.
- Ensure `.NET Framework 3.5 (includes .NET 2.0 and 3.0)` is enabled for legacy WiX toolchain flows (notably Python 3.10).

### 2) `buildrelease.bat` false success exit code

- A build can print `Build FAILED.` while process returns `0`.
- PSUB script has an output-based failure guard in step 4 to stop early.

### 3) SDK registry path mismatch

- Some environments expose SDK under WOW6432Node registry path.
- Verify both registry and include directory on disk.

### 4) Documentation packaging differs between 3.10 and 3.11+

- Python `3.10.x` MSI packaging expects compiled HTML Help output (`Doc\build\htmlhelp\python*.chm`).
- Python `3.11.x` and `3.12.x` MSI packaging expects HTML documentation under `Doc\build\html\`.
- PSUB now chooses the correct documentation build mode automatically before running `buildrelease.bat --skip-doc`.
- If you need to reproduce manually:
- For `3.10.x`, run `Doc\make.bat htmlhelp` after `Tools\msi\get_externals.bat`.
- For `3.11.x` and `3.12.x`, run `Doc\make.bat html` after `Tools\msi\get_externals.bat`.

### 5) `pkg_resources` / older Sphinx compatibility in doc venv

- Symptom: documentation environment check reports missing `pkg_resources` even though `setuptools` is installed.
- Root cause: naive import checks can misread the environment during scripted validation.
- PSUB now uses a more robust package availability check before deciding whether to install a compatible `setuptools<81`.

## Evidence to keep

- Source version and source URLs
- Integrity verification results
- Build command and `SourcePath`
- Visual Studio version, edition, and installation path used
- Build log path
- Artifact output path and zip path
- Final PSUB release zip name, expected in the form `Python-<version>_<timestamp>.zip`
- Any warnings/errors and final disposition

`Build-PythonRelease.ps1` now captures this evidence automatically after a successful build by default.

If you need to rerun the capture manually or collect evidence separately, run:

`.\Script\Capture-BuildEvidence.ps1 -SourcePath "C:\src\Python-<version>\Python-<version>" -ReleaseRoot "C:\python-releases"`

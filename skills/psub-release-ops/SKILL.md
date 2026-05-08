---
name: psub-release-ops
description: Use when operating PSUB release workflows: check latest CPython security source releases, download and verify source archives, run PSUB builds on Windows, and troubleshoot MSI/WiX build failures.
---

# PSUB Release Ops

Use this skill for repeatable CPython security-release operations in this repository.

## When to use

- User asks to check if a new Python 3.10/3.11/3.12 security release exists.
- User asks to download source-only CPython release files for local build.
- User asks to run PSUB build pipeline and summarize results.
- User asks to troubleshoot PSUB MSI/WiX failures.

## Workflow

1. Detect latest patch version for requested minor line (`3.10`, `3.11`, `3.12`) on python.org.
2. Download source archives into `C:\src\Python-<version>\`.
3. Verify integrity using official published metadata:
- Prefer official cryptographic signatures (`.asc`, and `.sigstore` when available).
- Use official checksums from release page if provided.
4. Extract to `C:\src\Python-<version>\Python-<version>`.
5. Validate required paths:
- `PCbuild`
- `Tools\msi`
- `Doc\requirements.txt`
6. Run PSUB build:
- `.\Script\Build-PythonRelease.ps1 -SourcePath "C:\src\Python-<version>\Python-<version>"`
7. Report:
- exact version built
- command used
- output folder and zip
- key warnings/errors and next action

## Repository specifics

- Build script: `Script/Build-PythonRelease.ps1`
- UI wrapper: `Script/Build-PythonRelease-UI-Simple.ps1`
- Logs folder: `logs/`
- Docs folder: `documentation/`

## Known behavior to remember

- Python 3.10 MSI builds may depend on legacy WiX/MSBuild components and can fail with `MSB4062` if `.NET Framework 3.5` is not enabled.
- Python 3.10 release packaging expects compiled HTML Help (`Doc\build\htmlhelp\python*.chm`) before MSI packaging.
- Python 3.11 and 3.12 release packaging expects HTML documentation under `Doc\build\html\` rather than CHM-only output.
- `buildrelease.bat` can sometimes output `Build FAILED.` even when process exit code is `0`.
- PSUB script has been updated to detect this mismatch and fail early in step 4.
- `Build-PythonRelease.ps1` now chooses the documentation build mode by source version:
- `3.10.x` uses `Doc\make.bat htmlhelp`
- `3.11.x` and `3.12.x` use `Doc\make.bat html`
- `Build-PythonRelease.ps1` now captures build evidence automatically after a successful build unless `-CaptureEvidence $false` is used.

## References

- Build/release checklist: `references/release-checklist.md`
- Troubleshooting map: `references/troubleshooting.md`

# Release Checklist (PSUB)

## 1. Confirm release target

- Confirm requested minor line: `3.10`, `3.11`, or `3.12`.
- Check latest patch version on python.org.
- Confirm if release is source-only or includes binaries.

## 2. Download source files

- Create `C:\src\Python-<version>\`.
- Download source archive (`.tar.xz` preferred).
- Download signature file (`.asc`).
- Optional: download `.sigstore` if available.

## 3. Verify integrity

- Validate against official release metadata.
- Verify signature if GPG and keys are available.
- Stop immediately on mismatch.

## 4. Extract and validate layout

- Extract under `C:\src\Python-<version>\`.
- Confirm source root exists at:
- `C:\src\Python-<version>\Python-<version>`
- Confirm required paths:
- `PCbuild`
- `Tools\msi`
- `Doc\requirements.txt`

## 5. Preflight before build

- `git --version`
- bootstrap Python available (3.10 or 3.12)
- Visual Studio C++ toolchain installed
- Windows 10 SDK installed (10.0.19041.0+)

## 6. Build

- Run:
`.\Script\Build-PythonRelease.ps1 -SourcePath "C:\src\Python-<version>\Python-<version>"`
- Capture log path from output.

## 7. Validate outputs

- Confirm `PCbuild\amd64\en-us` exists under source root.
- Confirm expected installers and embedded zip exist.
- Confirm release folder + zip under configured `ReleaseRoot`.

## 8. Record evidence

- Version, source URLs, hash/signature results.
- Build start/end time and total duration.
- Log file path.
- Any warnings and remediation notes.

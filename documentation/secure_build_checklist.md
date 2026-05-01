# Secure Build Checklist

Use this checklist when you want a repeatable and inspectable build of a Python release on a private machine.

## 1. Prepare a clean build environment

- Build inside a dedicated Windows VM if possible.
- Take a VM snapshot before installing tools or starting the build.
- Keep the machine focused on release work only while the build is running.
- Avoid reusing an old `doc-venv`; recreate it for each release.

## 2. Verify the source inputs

- Download the CPython source archive and signature from official sources.
- Record the exact version and URL in your release notes.
- Verify SHA256 against official metadata.
- Verify signatures when available.
- Extract the archive into a clean source folder such as `C:\src\Python-<version>\Python-<version>`.

## 3. Verify the toolchain

- Confirm the bootstrap Python is a real `python.exe` from a python.org installation.
- Confirm Visual Studio and the Windows SDK versions you plan to use.
- Record the actual versions used in the build.
- If you use Git, record the PSUB commit hash before starting.

## 4. Build from a known state

- Start from a clean PSUB working tree.
- Run the build with an explicit `-SourcePath`.
- Keep the build log.
- Avoid unrelated browsing, downloads, or software installs during the build session.

## 5. Capture evidence after the build

Run:

```powershell
.\Script\Capture-BuildEvidence.ps1 -SourcePath "C:\src\Python-3.11.14\Python-3.11.14" -ReleaseRoot "C:\python-releases"
```

The script writes evidence into `ReleaseDir\_evidence\`:

- `build-metadata.json`
- `pip-freeze.txt`
- `artifact-sha256.txt`
- `summary.txt`

## 6. Review the output artifacts

- Confirm the expected installer files were produced.
- Confirm the release zip name matches the intended version.
- Review `artifact-sha256.txt` and keep it with your release notes.
- Run your antivirus or endpoint scan on the final artifacts if that is part of your process.

## 7. Preserve the record

- Copy the evidence bundle into your long-term release record.
- Fill out [release_record_template.md](release_record_template.md).
- Keep the source checksums, build logs, evidence files, and final artifact checksums together.

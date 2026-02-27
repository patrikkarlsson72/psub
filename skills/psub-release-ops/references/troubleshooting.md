# Troubleshooting (PSUB)

## MSI step fails with `MSB4062` in WiX task

Symptom:
- `wix2010.targets(...): error MSB4062`
- Missing assembly similar to `Microsoft.Build.Utilities, Version=2.0.0.0`

Likely cause:
- Legacy WiX/MSBuild dependency not available in current environment.

Actions:
1. Re-run `Tools\msi\get_externals.bat`.
2. Ensure required legacy framework components are enabled (notably .NET 3.5 where required by WiX toolchain).
3. Re-run `Tools\msi\buildrelease.bat -x64` in VS Native Tools prompt.

## `buildrelease.bat` reports failure but exits 0

Symptom:
- Console/log contains `Build FAILED.`
- Process exit code still `0`

Status in this repo:
- `Script/Build-PythonRelease.ps1` includes a safeguard to fail early in step 4 when output includes build failure markers.

## Git warnings in `pythoncore.vcxproj` (code 128)

Symptom:
- warnings around `git name-rev`, `git rev-parse`, `git describe`

Notes:
- Often non-fatal metadata warnings in source snapshots.
- If build completes and artifacts are present, treat as warning.

## Output folder missing: `PCbuild\amd64\en-us`

Symptom:
- Step 5 fails because output folder does not exist.

Root cause:
- Usually an upstream MSI build failure.

Action:
- Inspect step 4 output and log lines around `Build FAILED.` and `error MSBxxxx`.

## SDK detection differences by registry path

Symptom:
- A script says SDK missing, but SDK is installed.

Notes:
- Some systems store SDK values under:
`HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0`
- Also validate include directory:
`C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0`

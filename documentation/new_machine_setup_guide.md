# New Machine Setup Guide

This guide walks through a clean-machine setup for PSUB using `Visual Studio Professional 2022` as the recommended baseline.

## Goal

Verify that PSUB works on a fresh Windows machine with no dependency on an older `Visual Studio 2019` installation.

## Install Order

1. Install `Visual Studio Professional 2022`.
2. In Visual Studio Installer, select the `Desktop development with C++` workload.
3. In `Individual components`, ensure these are installed:
   - `MSVC v143 - VS 2022 C++ x64/x86 build tools`
   - `MSVC v143 - VS 2022 C++ ARM64 build tools`
   - `Windows 10 SDK (10.0.19041.0)` or newer
4. Optionally install the `Python development` workload if you want the extra tooling, but it is not required for PSUB builds.
5. Optionally install `Git for Windows` if you want normal repo workflows on the machine.
6. Install bootstrap Python:
   - Recommended: `Python 3.12` from `python.org`
   - Supported alternative: `Python 3.10`
   - For PSUB, prefer the normal Windows installer over the Microsoft Store package.
   - Check `Add Python to PATH` during installation.
7. If you plan to test `Python 3.10` MSI builds, enable `.NET Framework 3.5` in Windows Features.

## Quick Verification

Open a normal PowerShell window and confirm the basics:

```powershell
python --version
where.exe python
py -0p
```

Optional:

```powershell
git --version
```

Expected Python result:

- `python --version` shows `Python 3.12.x` or `Python 3.10.x`
- `where.exe python` points to a real install path such as `C:\Users\<User>\AppData\Local\Programs\Python\Python312\python.exe`
- Avoid `C:\Users\<User>\AppData\Local\Microsoft\WindowsApps\python.exe` for PSUB, because that is typically only a Windows app alias

If you want to verify the compiler manually, open `x64 Native Tools Command Prompt for VS 2022` and run:

```cmd
where cl
cl
```

## Clone PSUB

Choose a working folder and clone the repository:

```powershell
git clone https://github.com/patrikkarlsson72/psub.git
cd psub
```

## First PSUB Check

Start the web UI:

```powershell
.\Script\Build-PythonRelease-UI-Simple.ps1 -Port 8080
```

Open `http://localhost:8080` and confirm that these prerequisites are marked ready:

- Visual Studio
- Windows SDK
- Bootstrap Python
- Git should appear as recommended rather than blocking

If `Auto-Detect` does not find Python, enter the full path to the real `python.exe` from the python.org installation. Do not use the `WindowsApps` alias path.
If the detected Windows SDK shown in prerequisites is newer than `10.0.19041.0`, PSUB should now prefill that detected version automatically in the build settings.
If Git is missing, the environment can still be ready for build as long as the required toolchain, SDK, and bootstrap Python are present.

## First CLI Test

From normal PowerShell, run the CLI build script and let PSUB bootstrap the Visual Studio environment automatically:

```powershell
.\Script\Build-PythonRelease.ps1 -SourcePath "C:\src\Python-3.11.14\Python-3.11.14" -BootstrapPython "C:\Users\<User>\AppData\Local\Programs\Python\Python312\python.exe"
```

Expected result:

- PSUB detects `Visual Studio 2022 Professional`
- PSUB imports the `vcvars64.bat` environment automatically
- PSUB uses the installed Windows SDK version if the old default is not present
- The build proceeds into the normal `PCbuild` and `Tools\msi` steps

## Recommended Test Sequence

1. Test `Python 3.11.x` or `Python 3.12.x` first.
2. Confirm the build gets through prerequisite setup and externals download.
3. Run a full installer build.
4. After that succeeds, optionally test `Python 3.10.x` to verify the legacy WiX/.NET 3.5 path.
5. For `Python 3.10.x`, confirm `doc.msi` is present, since that path depends on compiled HTML Help documentation being created successfully.

## What to Record

For the clean-machine verification, capture:

- Visual Studio version and edition
- Windows SDK version
- Bootstrap Python version
- Git version if installed
- PSUB commit hash used
- Whether the UI prerequisites check passed
- Whether CLI worked from normal PowerShell
- Final build result and output path
- Final release zip name, which should follow `Python-<version>_<timestamp>.zip`

## Success Criteria

The clean-machine test is successful when:

- `Visual Studio Professional 2022` is the only Visual Studio installation
- PSUB detects it correctly in the UI
- `Build-PythonRelease.ps1` runs from normal PowerShell without requiring a manual Developer Prompt
- A full build completes for at least one supported Python release line
- Optional Git installation does not prevent PSUB from reporting the environment as ready

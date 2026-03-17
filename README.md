# PSUB - Python Security Update Builder

PSUB is a PowerShell toolkit for building Python 3.10, 3.11, and 3.12 security releases on Windows. It provides a command-line build script and a simple local web UI for running builds with the required Windows toolchain.

This repository is organized as a practical build tool first. The README is intentionally short and focused on getting started quickly.

## Quick Overview

- Windows-based toolkit for Python security release builds
- Supports Python `3.10`, `3.11`, and `3.12`
- Includes both a CLI workflow and a local web UI

## Required Project Layout

Keep these folders together in the same relative structure:

```text
PSUB/
|-- Script/
|-- documentation/
`-- assets/
```

`output/` and log files are local runtime artifacts and do not need special handling in this README.

## Prerequisites

Before starting a build, make sure the machine has:

- Visual Studio 2022 with the required C++ toolchain components
- Visual Studio 2019 only if you need the fallback path
- Windows 10 SDK `10.0.19041.0` or later
- Bootstrap Python `3.10` or `3.12`
- Git for Windows if you want repo operations and build metadata support
- .NET Framework 3.5 for legacy WiX/MSI build flows such as Python 3.10

For the full checklist and setup details, see [documentation/prerequisites_overview.md](documentation/prerequisites_overview.md).

## Quick Start

### 1. Prepare CPython source

Extract the CPython source tree to a local folder, for example:

```powershell
C:\src\Python-3.11.14\Python-3.11.14
```

### 2. Run the CLI build

From the repository root:

```powershell
.\Script\Build-PythonRelease.ps1 -SourcePath "C:\src\Python-3.11.14\Python-3.11.14"
```

Useful optional parameters include:

- `-BootstrapPython` to point to the Python used for helper scripts
- `-VenvName` to control the documentation virtual environment folder
- `-ReleaseRoot` to choose where collected release output is stored
- `-WinSdkVersion` to request a specific installed Windows SDK version

### 3. Or start the web UI

```powershell
.\Script\Build-PythonRelease-UI-Simple.ps1 -Port 8080
```

Then open `http://localhost:8080` in your browser.

The UI helps you check prerequisites, read the local documentation, configure build settings, and monitor build progress.

## More Documentation

- [documentation/prerequisites_overview.md](documentation/prerequisites_overview.md)
- [documentation/python_build_minimal_guide.md](documentation/python_build_minimal_guide.md)
- [documentation/release_runbook.md](documentation/release_runbook.md)

## Supported Python Versions

- Python 3.10.x
- Python 3.11.x
- Python 3.12.x

## License

This project is provided as-is for building Python distributions. When distributing built binaries, ensure compliance with the [Python license](https://docs.python.org/3/license.html).

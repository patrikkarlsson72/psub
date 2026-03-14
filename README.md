# PSUB - Python Security Update Builder

A PowerShell-based toolkit for building Python security releases (3.10, 3.11, 3.12) on Windows for enterprise deployment.

## 🎯 Purpose

PSUB simplifies the process of building custom Python security releases from source, generating enterprise-ready installers (EXE + MSI) with all necessary components.

## 📦 What's Included

- **Build-PythonRelease.ps1** - Core build automation script
- **Build-PythonRelease-UI-Simple.ps1** - Web-based UI for easier build management
- **Documentation** - Step-by-step guides with interactive web viewer
- **Prerequisites Checker** - Automated verification of required tools

## 📁 Installation & Deployment

### Folder Structure

PSUB requires a specific folder structure. The entire project folder can be placed anywhere on your system, but the relative structure must be maintained:

```
PSUB/
├── Script/
│   ├── Build-PythonRelease-UI-Simple.ps1
│   └── Build-PythonRelease.ps1
├── documentation/
│   ├── prerequisites_overview.md
│   ├── setup_visual_studio.md
│   ├── setup_windows_sdk.md
│   ├── setup_bootstrap_python.md
│   ├── setup_git.md
│   └── python_build_minimal_guide.md
└── assets/
    └── (background images and other assets)
```

### Installing on Another Machine

1. **Copy the entire PSUB folder** to the target machine (maintain the folder structure)
2. The folder can be placed anywhere (e.g., `C:\Tools\PSUB` or `D:\PythonBuilder\PSUB`)
3. Run the scripts from within the `Script/` folder, or use absolute paths

**Important:** Do not move individual scripts or folders separately - they must remain in their relative positions.

## 🚀 Quick Start

### Prerequisites

- Visual Studio 2022 (Professional recommended; Community/Enterprise also supported)
  - Desktop development with C++
  - Python development workload (optional)
  - MSVC toolsets for x64/x86 and ARM64
  - Visual Studio 2019 remains supported as a fallback
- Windows 10 SDK (10.0.19041.0)
- Bootstrap Python (3.10 or 3.12)
- Git for Windows (required for MSI installer build)
- .NET Framework 3.5 (includes .NET 2.0 and 3.0), required for legacy WiX/MSI builds (notably Python 3.10)

### Basic Usage

1. Extract CPython source to a directory (e.g., `C:\src\Python-3.11.14`)

2. Run the build script:

```powershell
.\Script\Build-PythonRelease.ps1 -SourcePath "C:\src\Python-3.11.14\Python-3.11.14"
```

### Using the Web UI

The web UI provides a user-friendly interface with automated checks and documentation:

```powershell
.\Script\Build-PythonRelease-UI-Simple.ps1 -Port 8080
```

Then open your browser to `http://localhost:8080`

**Web UI Features:**
- ✅ **Automated Prerequisites Checker** - Verifies Visual Studio, Windows SDK, and Bootstrap Python
- ✅ **Git Detection** - Verifies Git for Windows is installed and available on PATH
- 📚 **Interactive Documentation Viewer** - Access setup guides directly from the UI
- 🔧 **Build Configuration** - Configure build parameters through a web interface
- 📊 **Real-time Build Status** - Monitor build progress and logs

The documentation guides are rendered as formatted HTML with proper styling for easy reading.

## 📚 Documentation

### Available Guides

- **[Prerequisites Overview](documentation/prerequisites_overview.md)** - Complete checklist of required tools
- **[Visual Studio Setup](documentation/setup_visual_studio.md)** - Installing and configuring VS 2022/2019
- **[Windows SDK Setup](documentation/setup_windows_sdk.md)** - Installing the required SDK version
- **[Bootstrap Python Setup](documentation/setup_bootstrap_python.md)** - Installing Python for build scripts
- **[Git Setup](documentation/setup_git.md)** - Installing Git for Windows
- **[Minimal Build Guide](documentation/python_build_minimal_guide.md)** - Step-by-step build instructions

All documentation is accessible through the web UI at `/api/docs/<guide-name>` or directly from the `documentation/` folder.

### Release Operations

- **[Release Runbook](documentation/release_runbook.md)** - End-to-end operational flow for source download, verification, build, and evidence capture
- **[Release Record Template](documentation/release_record_template.md)** - Reusable template for recording each release run
- **[Session Notes (2026-02-27)](documentation/session_notes_2026-02-27.md)** - Summary of recent troubleshooting and release preparation
- **[PSUB Release Ops Skill](skills/psub-release-ops/SKILL.md)** - Local skill for repeatable release checks, downloads, builds, and troubleshooting

## 🎯 Output

The build process generates:
- `python-<version>-amd64.exe` - Main installer
- `core.msi`, `pip.msi`, `path.msi`, `tcltk.msi`, `dev.msi`, `doc.msi` - Component installers
- `python-<version>-embed-amd64.zip` - Embeddable distribution

## 🛠️ Supported Python Versions

- Python 3.10.x
- Python 3.11.x
- Python 3.12.x

## 📝 License

This project is provided as-is for building Python distributions. Please ensure compliance with [Python's license](https://docs.python.org/3/license.html) when distributing built binaries.

## 🤝 Contributing

Contributions welcome! Please feel free to submit issues or pull requests.

## 🙏 Acknowledgments

Built to simplify Python security release deployment in enterprise environments.




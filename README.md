# PSUB - Python Security Update Builder

A PowerShell-based toolkit for building Python security releases (3.10, 3.11, 3.12) on Windows for enterprise deployment.

## 🎯 Purpose

PSUB simplifies the process of building custom Python security releases from source, generating enterprise-ready installers (EXE + MSI) with all necessary components.

## 📦 What's Included

- **Build-PythonRelease.ps1** - Core build automation script
- **Build-PythonRelease-UI-Simple.ps1** - Web-based UI for easier build management
- **Build-PythonRelease-UI.ps1** - Advanced UI with additional features
- **Documentation** - Step-by-step guides for building Python releases

## 🚀 Quick Start

### Prerequisites

- Visual Studio 2019 (Community Edition or higher)
  - Desktop development with C++
  - Python development workload
  - MSVC v142 toolsets (x64/x86, ARM64, ARM64EC)
- Windows 10 SDK (10.0.19041.0)
- Bootstrap Python (3.10 or 3.12)

### Basic Usage

1. Extract CPython source to a directory (e.g., `C:\src\Python-3.11.14`)

2. Run the build script:

```powershell
.\Script\Build-PythonRelease.ps1 -SourcePath "C:\src\Python-3.11.14\Python-3.11.14"
```

### Using the Web UI

```powershell
.\Script\Build-PythonRelease-UI-Simple.ps1 -Port 8080
```

Then open your browser to `http://localhost:8080`

## 📚 Documentation

See the [Minimal Build Guide](documentation/python_build_minimal_guide.md) for detailed step-by-step instructions.

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


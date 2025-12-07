# Setting Up Visual Studio 2019 for Python Builds

This guide will help you install and configure Visual Studio 2019 with all the required components for building Python security releases.

## Download Visual Studio 2019

1. Download Visual Studio 2019 from: https://visualstudio.microsoft.com/vs/older-downloads/
2. Choose **Community**, **Professional**, or **Enterprise** edition
3. Run the installer

## Required Workloads

During installation, select these **workloads**:

### Desktop development with C++
- This is the core workload needed for building Python
- Includes the MSVC compiler and build tools

### Python development (optional but recommended)
- Provides Python tools and IntelliSense
- Not strictly required for building, but helpful

## Required Individual Components

After selecting workloads, go to the **Individual components** tab and ensure these are installed:

### MSVC v142 - VS 2019 C++ Build Tools

You need **all three** of these toolchains:

1. **MSVC v142 - VS 2019 C++ x64/x86 build tools (v14.29)**
   - Required for building x64 and x86 Python binaries

2. **MSVC v142 - VS 2019 C++ ARM64 build tools (v14.29)**
   - Required for ARM64 builds
   - Also required by WiX 3.14 even when building x64 installers

### Windows 10 SDK

- **Windows 10 SDK (10.0.19041.0)** or later
- Should be included with the Desktop development workload
- Verify it's installed in: `C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0`

## Installation Steps

1. **Start the Visual Studio Installer**
2. **Click "Modify"** on your VS 2019 installation
3. **Select workloads:**
   - ✅ Desktop development with C++
   - ✅ Python development (optional)
4. **Go to Individual components tab**
5. **Search for "v142"** and ensure both toolchain variants are checked:
   - MSVC v142 - VS 2019 C++ x64/x86 build tools
   - MSVC v142 - VS 2019 C++ ARM64 build tools
6. **Click "Modify"** to install

## Verify Installation

After installation, verify Visual Studio is set up correctly:

1. Open **x64 Native Tools Command Prompt for VS 2019** (search in Start menu)
2. Run: `where cl`
   - Should show: `C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Tools\MSVC\...\bin\Hostx64\x64\cl.exe`
3. Run: `cl`
   - Should show the Microsoft C/C++ compiler version

## Common Issues

### "Visual Studio not found" error
- Ensure Visual Studio 2019 is installed (not 2022 or 2017)
- Check the installation path: `C:\Program Files (x86)\Microsoft Visual Studio\2019\`

### Missing toolchains error
- Open Visual Studio Installer
- Click "Modify" on VS 2019
- Go to Individual components
- Search for "v142" and install all three toolchain variants

### Wrong SDK version
- The build requires Windows 10 SDK 10.0.19041.0
- Install it via Visual Studio Installer → Individual components
- Or download from: https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/

## Next Steps

Once Visual Studio 2019 is installed with all required components:
1. Continue with [Windows SDK Setup](setup_windows_sdk.md) (if not already installed)
2. Install [Bootstrap Python](setup_bootstrap_python.md)
3. Return to the PSUB web UI and check prerequisites again


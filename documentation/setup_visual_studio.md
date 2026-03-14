# Setting Up Visual Studio 2022 for Python Builds

This guide will help you install and configure Visual Studio 2022 with all the required components for building Python security releases. Visual Studio 2019 is still supported when you need compatibility with an older workstation, but Visual Studio Professional 2022 is the recommended baseline.

## Download Visual Studio 2022

1. Download Visual Studio 2022 from: https://visualstudio.microsoft.com/downloads/
2. Choose **Professional** edition if available in your environment
3. Community and Enterprise editions are also supported
4. Run the installer

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

### MSVC C++ Build Tools

You need the x64/x86 and ARM64 toolchains available in the selected Visual Studio installation:

1. **MSVC v143 - VS 2022 C++ x64/x86 build tools**
   - Required for building x64 and x86 Python binaries

2. **MSVC v143 - VS 2022 C++ ARM64 build tools**
   - Required for ARM64 builds
   - Also required by WiX 3.14 even when building x64 installers

3. **If you are using Visual Studio 2019 instead**
   - Install the equivalent `MSVC v142` x64/x86 and ARM64 components

### Windows 10 SDK

- **Windows 10 SDK (10.0.19041.0)** or later
- Should be included with the Desktop development workload
- Verify it's installed in: `C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0`

## Installation Steps

1. **Start the Visual Studio Installer**
2. **Click "Modify"** on your VS 2022 installation
3. **Select workloads:**
   - ✅ Desktop development with C++
   - ✅ Python development (optional)
4. **Go to Individual components tab**
5. **Search for "MSVC"** and ensure the x64/x86 and ARM64 toolchain variants are checked for your installed VS version
6. **Click "Modify"** to install

## Verify Installation

After installation, verify Visual Studio is set up correctly:

1. Open **x64 Native Tools Command Prompt for VS 2022** (search in Start menu), or run PSUB from normal PowerShell and let the script bootstrap `vcvars64.bat` automatically
2. Run: `where cl`
   - Should show a path under your Visual Studio 2022 installation, for example `C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\...\bin\Hostx64\x64\cl.exe`
3. Run: `cl`
   - Should show the Microsoft C/C++ compiler version

## Common Issues

### "Visual Studio not found" error
- Ensure Visual Studio 2022 or 2019 is installed with the C++ workload
- Check the installation path under either:
  `C:\Program Files\Microsoft Visual Studio\2022\`
  `C:\Program Files (x86)\Microsoft Visual Studio\2019\`

### Missing toolchains error
- Open Visual Studio Installer
- Click "Modify" on your installed Visual Studio version
- Go to Individual components
- Search for `MSVC` and install the x64/x86 and ARM64 variants for that version

### Wrong SDK version
- The build requires Windows 10 SDK 10.0.19041.0
- Install it via Visual Studio Installer → Individual components
- Or download from: https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/

## Next Steps

Once Visual Studio 2022 is installed with all required components:
1. Continue with [Windows SDK Setup](setup_windows_sdk.md) (if not already installed)
2. Install [Bootstrap Python](setup_bootstrap_python.md)
3. Return to the PSUB web UI and check prerequisites again


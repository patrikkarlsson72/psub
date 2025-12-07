# Setting Up Windows SDK for Python Builds

This guide explains how to install the required Windows 10 SDK version for building Python security releases.

## Required Version

**Windows 10 SDK version 10.0.19041.0** (or later)

This is the minimum required version. The build process will use this specific SDK version.

## Installation Methods

### Method 1: Via Visual Studio Installer (Recommended)

1. Open **Visual Studio Installer**
2. Click **"Modify"** on your Visual Studio 2019 installation
3. Go to the **Individual components** tab
4. Search for **"Windows 10 SDK"**
5. Check **"Windows 10 SDK (10.0.19041.0)"** or a later version
6. Click **"Modify"** to install

### Method 2: Standalone Installer

1. Download Windows 10 SDK from:
   https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/
2. Download version **10.0.19041.0** or later
3. Run the installer
4. Select **"Windows SDK for Desktop C++ x86 and x64"** during installation

## Verify Installation

After installation, verify the SDK is installed:

1. Check the installation directory:
   ```
   C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0
   ```
   This folder should exist and contain header files.

2. Check the Lib directory:
   ```
   C:\Program Files (x86)\Windows Kits\10\Lib\10.0.19041.0
   ```
   This folder should contain library files.

## Common Issues

### SDK Not Found Error

**Problem:** Build script reports "Windows SDK not found"

**Solution:**
- Verify the SDK is installed in the correct location
- Check that version 10.0.19041.0 or later is installed
- Reinstall via Visual Studio Installer if needed

### Wrong SDK Version

**Problem:** Build uses wrong SDK version

**Solution:**
- The build script uses the `WinSdkVersion` parameter (default: 10.0.19041.0)
- Ensure this exact version or a compatible later version is installed
- You can specify a different version in the build configuration if needed

### Multiple SDK Versions

**Problem:** Multiple SDK versions installed, unsure which one is used

**Solution:**
- The build script will use the version specified in `WinSdkVersion` parameter
- Default is 10.0.19041.0
- Ensure this version is installed

## Next Steps

Once Windows SDK is installed:
1. Verify Visual Studio 2019 is set up: [Visual Studio Setup Guide](setup_visual_studio.md)
2. Install [Bootstrap Python](setup_bootstrap_python.md)
3. Return to the PSUB web UI and check prerequisites again


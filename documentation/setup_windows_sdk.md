# Setting Up Windows SDK for Python Builds

This guide explains how to install the required Windows 10 SDK version for building Python security releases.

## Required Version

**Windows 10 SDK version 10.0.19041.0** (or later)

This is the minimum required version. PSUB prefers the requested SDK version, but can automatically fall forward to a compatible installed SDK such as `10.0.26100.0` when that is what exists on the machine.

## Installation Methods

### Method 1: Via Visual Studio Installer (Recommended)

1. Open **Visual Studio Installer**
2. Click **"Modify"** on your Visual Studio 2022 or 2019 installation
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

3. If you have a newer SDK installed, that is fine.
   Example:
   ```
   C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0
   ```

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
- The build script still has a minimum/default value of `10.0.19041.0`
- PSUB now auto-detects the installed SDK in the UI and will fall forward to a compatible installed SDK in CLI builds
- You can still specify a different version manually in the build configuration if needed

### Multiple SDK Versions

**Problem:** Multiple SDK versions installed, unsure which one is used

**Solution:**
- The web UI should prefill the detected installed version
- The CLI will use the requested version when available, otherwise it will choose a compatible installed version
- Record the actual SDK version used in your build evidence

## Next Steps

Once Windows SDK is installed:
1. Verify Visual Studio 2022 or 2019 is set up: [Visual Studio Setup Guide](setup_visual_studio.md)
2. Install [Bootstrap Python](setup_bootstrap_python.md)
3. Return to the PSUB web UI and check prerequisites again


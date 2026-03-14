# Setting Up Bootstrap Python

This guide explains how to install and configure the bootstrap Python required for building Python security releases.

## What is Bootstrap Python?

Bootstrap Python is a pre-existing Python installation used to:
- Run build helper scripts
- Create the documentation virtual environment
- Execute Sphinx for building documentation

## Required Version

You need **Python 3.10** or **Python 3.12** installed.

**Important:** Python 3.13 is **NOT** supported as a bootstrap Python.

## Installation

### Option 1: Download from python.org (Recommended)

1. Go to https://www.python.org/downloads/
2. Download **Python 3.10.x** or **Python 3.12.x**
   - Choose the Windows installer (64-bit)
3. Run the installer
4. **Important:** Check **"Add Python to PATH"** during installation
5. Complete the installation
6. Prefer this option for PSUB on `Visual Studio Professional 2022`, because it provides a normal `python.exe` path that automation can use reliably

### Option 2: Microsoft Store

1. Open Microsoft Store
2. Search for "Python 3.10" or "Python 3.12"
3. Install the official Python from Python Software Foundation
4. Note: Store installations may have different path locations and may expose `python.exe` through `WindowsApps`
5. PSUB can reject `WindowsApps` aliases because they are often not directly runnable by build automation

## Verify Installation

After installation, verify Python is accessible:

1. Open a new Command Prompt or PowerShell window
2. Run: `python --version`
   - Should show: `Python 3.10.x` or `Python 3.12.x`
3. Run: `where python`
   - Should show the path to python.exe
4. If available, run: `py -0p`
   - Should list the installed interpreter path
5. Prefer a real install path such as `C:\Users\<YourUsername>\AppData\Local\Programs\Python\Python312\python.exe`
   - Avoid `C:\Users\<YourUsername>\AppData\Local\Microsoft\WindowsApps\python.exe`

## Common Installation Locations

Python is typically installed in one of these locations:

- `C:\Program Files\Python3XX\python.exe`
- `C:\Program Files (x86)\Python3XX\python.exe`
- `C:\Users\<YourUsername>\AppData\Local\Programs\Python\Python3XX\python.exe`
- `C:\Python3XX\python.exe`

## Using the PSUB Auto-Detect Feature

The PSUB web UI has an **"Auto-Detect"** button that will:
1. Search common installation locations
2. Check `py -0p` when the Python launcher is installed
3. Check `python` from `PATH`
4. Verify the Python version (3.10 or 3.12)
5. Ignore `WindowsApps` alias paths that are not suitable for PSUB automation

Click the **"Auto-Detect"** button next to the Bootstrap Python field in the web UI.

## Manual Path Entry

If auto-detect doesn't find your Python installation:

1. Find your Python installation:
   - Run `where python` in Command Prompt
   - Run `py -0p` if the Python launcher is installed
   - Or check the installation locations listed above
2. Enter the full path to `python.exe` in the Bootstrap Python field
   - Example: `C:\Users\YourName\AppData\Local\Programs\Python\Python312\python.exe`
3. Do not use `C:\Users\YourName\AppData\Local\Microsoft\WindowsApps\python.exe`

## Common Issues

### "Python not found" error

**Problem:** Build script can't find Python

**Solution:**
- Verify Python is installed: `python --version`
- Use the full path to `python.exe` (not just `python`)
- Prefer a python.org installation path instead of `WindowsApps\python.exe`
- Ensure you're using Python 3.10 or 3.12 (not 3.13)

### Wrong Python version

**Problem:** Python 3.13 or other unsupported version detected

**Solution:**
- Install Python 3.10 or 3.12
- Uninstall Python 3.13 if it's interfering
- Use the full path to the correct Python version

### Multiple Python installations

**Problem:** Multiple Python versions installed, unsure which one is used

**Solution:**
- Use the full path to the specific `python.exe` you want to use
- The build script uses exactly the path you provide
- Example: `C:\Program Files\Python312\python.exe`

### WindowsApps alias detected

**Problem:** PSUB reports that the selected path points to `WindowsApps\python.exe`

**Solution:**
- Install Python 3.12 or 3.10 from `python.org`
- Use the real `python.exe` path from that installation
- Re-run `where python` or `py -0p` and copy the non-`WindowsApps` path into PSUB

### Python not in PATH

**Problem:** `python` command not found, but Python is installed

**Solution:**
- Use the full path to `python.exe` instead
- Or reinstall Python and check "Add Python to PATH"
- Or manually add Python to your system PATH

## Next Steps

Once Bootstrap Python is installed:
1. Verify [Visual Studio 2022 / 2019](setup_visual_studio.md) is set up
2. Verify [Windows SDK](setup_windows_sdk.md) is installed
3. Return to the PSUB web UI
4. Click **"Auto-Detect"** to find your Python installation
5. Proceed with the build configuration


# Setting Up Git for Python Builds

This guide will help you install and configure Git for Windows, which is required for building Python security releases.

## Why Git is Required

Git is used during the MSI installer build process to:
- Embed version control information in the installer
- Determine the exact source version and commit
- Generate build metadata
- Track source provenance

Without Git, the `buildrelease.bat` script will fail with "Cannot find Git on PATH" error.

## Download Git for Windows

1. Download Git for Windows from: **https://git-scm.com/download/win**
2. Choose the **64-bit** installer (recommended)
3. Run the installer

## Installation Steps

### 1. Start the Installer

Run the downloaded installer as Administrator (recommended)

### 2. Select Components

Keep the default selections:
- ✅ Windows Explorer integration
- ✅ Git Bash Here
- ✅ Git GUI Here
- ✅ Associate .git* configuration files

### 3. **Important: Adjusting PATH Environment**

When you reach the "Adjusting your PATH environment" screen, select:

**"Git from the command line and also from 3rd-party software"**

This ensures Git is available in PowerShell, CMD, and the Visual Studio build tools.

### 4. Choose HTTPS Transport Backend

Select: **"Use the OpenSSL library"** (default)

### 5. Line Ending Configuration

Select: **"Checkout Windows-style, commit Unix-style line endings"** (default)

### 6. Terminal Emulator

Select: **"Use MinTTY"** (default)

### 7. Complete Installation

- Choose default options for remaining screens
- Click "Install"
- Click "Finish"

## Verify Installation

After installation, open a **new** PowerShell or Command Prompt window and verify:

```powershell
git --version
```

You should see output like:
```
git version 2.43.0.windows.1
```

## Alternative: Install via winget

If you have Windows Package Manager (winget) installed:

```powershell
winget install --id Git.Git -e --source winget
```

After installation, restart your terminal and verify with `git --version`

## Troubleshooting

### Git not found after installation

**Issue:** Running `git --version` gives "command not found" error

**Solution:**
1. Close all PowerShell/CMD windows
2. Open a **new** terminal window
3. If still not found, check if Git is in your PATH:
   ```powershell
   $env:PATH -split ';' | Select-String -Pattern 'Git'
   ```
4. If Git is not in PATH, manually add it:
   ```powershell
   $env:PATH += ";C:\Program Files\Git\cmd"
   ```
5. For permanent fix, add Git to System PATH in Environment Variables

### SSL Certificate Errors

**Issue:** Git operations fail with SSL certificate errors

**Solution:**
1. Update Windows certificates:
   ```powershell
   certutil -generateSSTFromWU roots.sst
   ```
2. Or configure Git to use Windows certificate store:
   ```bash
   git config --global http.sslBackend schannel
   ```

### Git works in Git Bash but not PowerShell

**Issue:** Git works in Git Bash but not in PowerShell or CMD

**Solution:**
This means Git wasn't added to the system PATH during installation. Either:
1. Reinstall Git and select "Git from the command line and also from 3rd-party software"
2. Or manually add `C:\Program Files\Git\cmd` to your system PATH

## Verify Git is Ready for Build

To ensure Git is properly configured for the Python build process:

1. Open **x64 Native Tools Command Prompt for VS 2022** or a normal PowerShell session
2. Run:
   ```cmd
   git --version
   ```
3. You should see the Git version number

If Git is available in the Visual Studio prompt or in normal PowerShell, it will work during the build process.

## Next Steps

Once Git is installed and verified:

1. Return to the [Prerequisites Overview](prerequisites_overview.md)
2. Verify all other prerequisites are installed
3. Proceed with the [Minimal Build Guide](python_build_minimal_guide.md)

## Additional Resources

- **Git for Windows Documentation:** https://gitforwindows.org/
- **Git Official Documentation:** https://git-scm.com/doc
- **Git Bash Tutorial:** https://www.atlassian.com/git/tutorials/git-bash

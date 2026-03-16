# ⚡ Minimal Guide: Build Python 3.10 / 3.11 / 3.12 Security Release on Windows
### (For Enterprise Deployment – EXE + MSI)

---

# 1. Install Required Tools

## Visual Studio Professional 2022 (recommended)
**Required workloads:**
- Desktop development with C++
- Python development (optional)

## Required MSVC toolsets
Ensure these **Individual Components** are installed:

- MSVC v143 – VS 2022 C++ x64/x86 build tools  
- MSVC v143 – VS 2022 C++ ARM64 build tools  

If you must use Visual Studio 2019 instead, install the equivalent `v142` components.

> WiX 3.14 requires ARM64 toolchains even when building x64 installers.

## Windows SDK
- Windows 10 SDK (10.0.19041.0 or later)
- If your machine has a newer installed SDK, for example `10.0.26100.0`, PSUB can use that version

## Python for bootstrap
Install:
- Python 3.10 **or**
- Python 3.12

(Not Python 3.13)

## Git for Windows
Install Git and ensure it's in your PATH:
- Download from: https://git-scm.com/download/win
- Recommended for repo operations and PSUB build metadata
- Verify installation: `git --version`

---

# 2. Prepare the Source

Extract CPython source to:

```
C:\src\Python-3.11.14\
```

---

# 3. Create Documentation Virtual Environment

In **x64 Native Tools Command Prompt for VS 2022** or normal PowerShell:

```bat
cd C:\src\Python-3.11.14
python -m venv doc-venv
doc-venv\Scripts\activate
pip install -r Doc\requirements.txt
```

---

# 4. Build CPython Binaries (optional but recommended)

```bat
cd PCbuild
get_externals.bat
build.bat -p x64 --pgo
```

---

# 5. Build the Windows Installer (.exe + .msi)

From repo root:

```bat
cd C:\src\Python-3.11.14
doc-venv\Scripts\activate
```

Set environment variables:

```bat
set PYTHON="C:\Users\<User>\AppData\Local\Programs\Python\Python312\python.exe"
set SPHINXBUILD=%CD%\doc-venv\Scripts\sphinx-build.exe
set WindowsTargetPlatformVersion=<installed-sdk-version>
set WindowsSDKVersion=<installed-sdk-version>\
```

Example on a current machine:

```bat
set WindowsTargetPlatformVersion=10.0.26100.0
set WindowsSDKVersion=10.0.26100.0\
```

Download external MSI dependencies:

```bat
Tools\msi\get_externals.bat
```

Build installer:

```bat
Tools\msi\buildrelease.bat -x64
```

For `Python 3.10.x`, make sure the HTML Help documentation build succeeds so that `doc.msi` can be packaged. In PSUB this is now handled automatically before the MSI packaging step.

---

# 6. Output Files

Generated files appear in:

```
PCbuild\amd64\en-us\
```

Included:

- python-<version>-amd64.exe  
- core.msi  
- pip.msi  
- path.msi  
- tcltk.msi  
- dev.msi  
- doc.msi  
- python-<version>-embed-amd64.zip  
- Python-<version>_<timestamp>.zip  (when collected by PSUB into `C:\python-releases`)

---

# 7. Common Issues and Fixes

### Build tools for v142/v143 missing
Install ARM64 toolsets.

### WiX errors
Run:
```
Tools\msi\get_externals.bat
```

### Sphinx import errors
```
pip install -r Doc\requirements.txt
```

### Python 3.10 doc/CHM errors
If `doc.msi` fails because `python31020.chm` or a similar `.chm` file is missing:
```
Tools\msi\get_externals.bat
Doc\make.bat htmlhelp
```
PSUB now automates this path and also pins a compatible setuptools version in the documentation venv when older Sphinx requires `pkg_resources`.

### Wrong compiler/toolset
Preferred:
``` 
x64 Native Tools Command Prompt for VS 2022
```

PSUB CLI can also bootstrap the Visual Studio environment automatically when started from normal PowerShell.

### Cannot find Git on PATH
Install Git for Windows:
```
Download from: https://git-scm.com/download/win
```
Or via winget:
```
winget install --id Git.Git -e --source winget
```
After installation, restart your terminal and verify:
```
git --version
```

---

# 🎉 Done!
This minimal guide reliably builds Python 3.10–3.12 security releases for enterprise deployment.

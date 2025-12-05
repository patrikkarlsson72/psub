# ⚡ Minimal Guide: Build Python 3.10 / 3.11 / 3.12 Security Release on Windows
### (For Enterprise Deployment – EXE + MSI)

---

# 1. Install Required Tools

## Visual Studio Community 2019 (recommended)
**Required workloads:**
- Desktop development with C++
- Python development

## Required MSVC toolsets
Ensure these **Individual Components** are installed:

- MSVC v142 – VS 2019 C++ x64/x86 build tools  
- MSVC v142 – VS 2019 C++ ARM64 build tools  
- MSVC v142 – VS 2019 C++ ARM64EC build tools  

> WiX 3.14 requires ARM64 toolchains even when building x64 installers.

## Windows SDK
- Windows 10 SDK (10.0.19041.0)

## Python for bootstrap
Install:
- Python 3.10 **or**
- Python 3.12

(Not Python 3.13)

---

# 2. Prepare the Source

Extract CPython source to:

```
C:\src\Python-3.11.14\
```

---

# 3. Create Documentation Virtual Environment

In **x64 Native Tools Command Prompt for VS 2019**:

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
set WindowsTargetPlatformVersion=10.0.19041.0
set WindowsSDKVersion=10.0.19041.0\
```

Download external MSI dependencies:

```bat
Tools\msi\get_externals.bat
```

Build installer:

```bat
Tools\msi\buildrelease.bat -x64
```

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

---

# 7. Common Issues and Fixes

### Build tools for v142/v143 missing
Install ARM64 + ARM64EC toolsets.

### WiX errors
Run:
```
Tools\msi\get_externals.bat
```

### Sphinx import errors
```
pip install -r Doc\requirements.txt
```

### Wrong compiler/toolset
Always use:
```
x64 Native Tools Command Prompt for VS 2019
```

---

# 🎉 Done!
This minimal guide reliably builds Python 3.10–3.12 security releases for enterprise deployment.

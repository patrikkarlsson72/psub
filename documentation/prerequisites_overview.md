# Prerequisites Overview

This guide provides an overview of all prerequisites needed to build Python security releases using PSUB.

## Quick Checklist

Before starting a build, ensure you have:

- `Visual Studio 2022` (Professional recommended; Community, Professional, or Enterprise supported)
  - Desktop development with C++ workload
  - MSVC toolchains (x64/x86, ARM64)
- `Visual Studio 2019` remains supported as a compatibility fallback
- `Windows 10 SDK` (version 10.0.19041.0 or later)
- `Bootstrap Python` (3.10 or 3.12, not 3.13)
- `Git for Windows` (required for MSI installer build)
- `.NET Framework 3.5` (includes .NET 2.0 and 3.0, required for legacy WiX/MSI flows such as Python 3.10)
- `CPython source code` (extracted to a local directory)

## Detailed Setup Guides

For detailed installation instructions, see:

1. **[Visual Studio 2022 / 2019 Setup](setup_visual_studio.md)**
   - Required workloads and components
   - How to verify installation
   - Troubleshooting common issues

2. **[Windows SDK Setup](setup_windows_sdk.md)**
   - Required SDK version
   - Installation methods
   - Verification steps

3. **[Bootstrap Python Setup](setup_bootstrap_python.md)**
   - Required Python version
   - Installation options
   - Path configuration

4. **[Git Setup](setup_git.md)**
   - Required for MSI installer build
   - Installation methods
   - Verification steps

5. **Windows Features (.NET 3.5)**
   - Enable `.NET Framework 3.5 (includes .NET 2.0 and 3.0)`
   - Required by legacy WiX toolchain used in some CPython MSI builds

## Verification

The PSUB web UI prerequisites checker should verify:

- Visual Studio 2019 or 2022 is installed
- Required MSVC toolchains are present
- Windows SDK is installed
- Bootstrap Python (3.10 or 3.12) is available
- .NET Framework 3.5 is enabled when legacy WiX/MSI build path is used

Note: Git detection is automated in the UI and included in the overall readiness check.

If any prerequisites are missing, the UI will show help links to relevant setup guides.

## System Requirements

- Operating System: Windows 10 or Windows 11
- Architecture: x64 (64-bit)
- Disk Space: At least 10 GB free (for source, build artifacts, and tools)
- RAM: 8 GB minimum, 16 GB recommended

## Installation Order

Recommended installation order:

1. Install Visual Studio 2022 Professional with required components
2. Verify Windows SDK is installed (usually included with VS)
3. Install Bootstrap Python (3.10 or 3.12)
4. Install Git for Windows
5. Enable .NET Framework 3.5 in Windows Features
6. Extract CPython source code
7. Run PSUB and check prerequisites

## Getting Help

If you encounter issues:

1. Check the setup guide for the component that is failing
2. Review "Common Issues" in each guide
3. Verify all components are installed in expected locations
4. Ensure you are using supported versions (VS 2022/2019, Python 3.10/3.12)

## Next Steps

Once all prerequisites are installed and verified:

1. Open the PSUB web UI
2. Confirm all prerequisites are ready
3. Configure build settings
4. Start the build

See the [Minimal Build Guide](python_build_minimal_guide.md) for step-by-step build instructions.

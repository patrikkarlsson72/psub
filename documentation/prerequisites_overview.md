# Prerequisites Overview

This guide provides an overview of all prerequisites needed to build Python security releases using PSUB.

## Quick Checklist

Before starting a build, ensure you have:

- ✅ **Visual Studio 2019** (Community, Professional, or Enterprise)
  - Desktop development with C++ workload
  - MSVC v142 toolchains (x64/x86, ARM64)
- ✅ **Windows 10 SDK** (version 10.0.19041.0 or later)
- ✅ **Bootstrap Python** (3.10 or 3.12, NOT 3.13)
- ✅ **CPython Source Code** (extracted to a local directory)

## Detailed Setup Guides

For detailed installation instructions, see:

1. **[Visual Studio 2019 Setup](setup_visual_studio.md)**
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

## Verification

The PSUB web UI includes a prerequisites checker that will:

- ✅ Check if Visual Studio 2019 is installed
- ✅ Verify all required MSVC toolchains are present
- ✅ Confirm Windows SDK is installed
- ✅ Detect Bootstrap Python (3.10 or 3.12)

If any prerequisites are missing, the UI will show help links to the relevant setup guides.

## System Requirements

- **Operating System:** Windows 10 or Windows 11
- **Architecture:** x64 (64-bit)
- **Disk Space:** At least 10 GB free (for source, build artifacts, and tools)
- **RAM:** 8 GB minimum, 16 GB recommended

## Installation Order

Recommended installation order:

1. Install **Visual Studio 2019** with required components
2. Verify **Windows SDK** is installed (usually included with VS)
3. Install **Bootstrap Python** (3.10 or 3.12)
4. Extract **CPython source code**
5. Run PSUB and check prerequisites

## Getting Help

If you encounter issues:

1. Check the specific setup guide for the component that's failing
2. Review the "Common Issues" section in each guide
3. Verify all components are installed in the correct locations
4. Ensure you're using the correct versions (VS 2019, not 2022; Python 3.10/3.12, not 3.13)

## Next Steps

Once all prerequisites are installed and verified:

1. Open the PSUB web UI
2. Check that all prerequisites show as ready
3. Configure your build settings
4. Start the build process

See the [Minimal Build Guide](python_build_minimal_guide.md) for step-by-step build instructions.


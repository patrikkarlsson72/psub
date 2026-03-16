# Setting Up Git for Windows

This guide explains when Git for Windows is useful with PSUB, why it is recommended, and why it is no longer treated as a hard prerequisite.

## Short answer

`Git for Windows` is recommended for PSUB, but it is not required to start the PSUB UI or to run a normal build from an extracted `python.org` source archive.

You should still install Git if you want to:

- clone or update the PSUB repository
- use normal repository workflows on the build machine
- capture extra build metadata when tools try to read Git information

## Why Git is recommended

Git helps in three practical ways:

1. It lets you clone and update the PSUB repository normally.
2. It provides a familiar toolchain on Windows build machines.
3. Some CPython build steps try to read Git metadata and may emit informational warnings if Git is available but the source tree is not itself a Git checkout.

## Why Git is not a strict PSUB requirement

PSUB usually builds from extracted source archives such as:

```text
C:\src\Python-3.11.15\Python-3.11.15
```

That source tree is normally **not** a Git repository. In that workflow:

- PSUB can still run the build successfully
- CPython build tooling may print Git-related warnings
- those warnings do not block a successful release build

PSUB's own build script only uses Git opportunistically for metadata capture when it is available.

## What the PSUB UI now does

In the prerequisites panel:

- `Git for Windows` is shown as **Recommended**
- missing Git is shown as optional rather than blocking
- overall environment readiness no longer depends on Git being installed

This matches the real-world verified flow on a clean machine.

## When you should install Git anyway

Install Git for Windows if any of these apply:

- you want to clone PSUB directly from GitHub
- you want normal `git status`, `git pull`, or `git push` workflows on the machine
- you want to inspect build-related metadata more easily
- the machine is a long-lived maintenance workstation rather than a minimal release-only box

## Install Git for Windows

1. Download Git for Windows from: **https://git-scm.com/download/win**
2. Choose the **64-bit** installer
3. Run the installer

## Recommended installer choice

When you reach the PATH screen, select:

**`Git from the command line and also from 3rd-party software`**

That makes Git available to:

- PowerShell
- Command Prompt
- Visual Studio developer shells

## Verify installation

Open a new PowerShell window and run:

```powershell
git --version
```

Expected result:

```text
git version 2.x.windows.x
```

## Troubleshooting

### Git not found after installation

If `git --version` fails:

1. Close all terminal windows
2. Open a new terminal
3. Check whether Git is on PATH:

```powershell
$env:PATH -split ';' | Select-String -Pattern 'Git'
```

4. If needed, add:

```text
C:\Program Files\Git\cmd
```

to your PATH.

### Git warnings during CPython build

You may still see warnings such as:

```text
fatal: not a git repository
```

when building from an extracted CPython source archive.

That is expected if the source tree came from `python.org` and is not a Git checkout. Those warnings do not by themselves mean the build failed.

## Next steps

After Git is installed, or if you choose not to install it, continue with:

- [Prerequisites Overview](prerequisites_overview.md)
- [New Machine Setup Guide](new_machine_setup_guide.md)
- [Minimal Build Guide](python_build_minimal_guide.md)

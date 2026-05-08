param(
    # Root of the extracted CPython source for the version you're building
    # Example: C:\src\Python-3.11.14\Python-3.11.14
    [string]$SourcePath = "C:\src\Python-3.11.14\Python-3.11.14",

    # Python used to run build helper scripts (3.10 or 3.12 recommended, NOT 3.13)
    [string]$BootstrapPython = "C:\Users\<User>\AppData\Local\Programs\Python\Python312\python.exe",

    # Name of the documentation venv folder inside SourcePath
    [string]$VenvName = "doc-venv",

    # Where to put the final release folder + zip
    [string]$ReleaseRoot = "C:\python-releases",

    # Windows SDK version to use
    [string]$WinSdkVersion = "10.0.19041.0",

    # Optional progress callback scriptblock for UI integration
    # Callback receives: [string]$Type ("info", "ok", "error", "step"), [string]$Message
    [scriptblock]$ProgressCallback = $null,

    # Optional build correlation id from UI
    [string]$BuildId = "",

    # Optional log file path
    [string]$LogPath = "",

    # Automatically capture a local evidence bundle after a successful build
    [bool]$CaptureEvidence = $true,

    # When true, evidence capture errors fail the overall build
    [bool]$FailOnEvidenceError = $false
)

$ErrorActionPreference = "Stop"
$script:BuildError = $null
$script:LogPath = $LogPath
$script:BuildStart = Get-Date
$script:SelectedVisualStudio = $null

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($script:LogPath)) {
        return
    }

    try {
        $logDir = Split-Path -Parent $script:LogPath
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $entry = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
        Add-Content -Path $script:LogPath -Value $entry -Encoding UTF8
    } catch {
        # Logging must not break the build.
    }
}

function Write-Info($msg) {
    Write-Host "[INFO ] $msg" -ForegroundColor Cyan
    Write-Log -Level "INFO" -Message $msg
    if ($ProgressCallback) {
        & $ProgressCallback "info" $msg
    }
}

function Write-Ok($msg) {
    Write-Host "[ OK  ] $msg" -ForegroundColor Green
    Write-Log -Level "OK" -Message $msg
    if ($ProgressCallback) {
        & $ProgressCallback "ok" $msg
    }
}

function Write-Err($msg) {
    Write-Host "[FAIL] $msg" -ForegroundColor Red
    Write-Log -Level "FAIL" -Message $msg
    if ($ProgressCallback) {
        & $ProgressCallback "error" $msg
    }
    $script:BuildError = $msg
}

function Write-Step($msg) {
    Write-Host "[STEP ] $msg" -ForegroundColor Yellow
    Write-Log -Level "STEP" -Message $msg
    if ($ProgressCallback) {
        & $ProgressCallback "step" $msg
    }
}

trap {
    $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
    Write-Err "Unhandled error: $errMsg"
    $duration = (Get-Date) - $script:BuildStart
    $failureMeta = @{
        result = "failed"
        durationSeconds = [int]$duration.TotalSeconds
    } | ConvertTo-Json -Compress
    Write-Log -Level "META" -Message $failureMeta
    exit 1
}

function Test-IsWindowsAppsPythonAlias {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return ($Path -match '(?i)\\AppData\\Local\\Microsoft\\WindowsApps\\python(?:3(?:\.\d+)?)?\.exe$')
}

function Get-VsWherePath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-InstalledWindowsSdkVersions {
    $sdkPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Include"
    if (-not (Test-Path $sdkPath)) {
        return @()
    }

    try {
        return @(
            Get-ChildItem -Path $sdkPath -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                Sort-Object {
                    try { [version]$_.Name } catch { [version]"0.0" }
                } -Descending |
                ForEach-Object { $_.Name }
        )
    } catch {
        return @()
    }
}

function Resolve-WindowsSdkVersion {
    param([string]$RequestedVersion)

    $installedVersions = @(Get-InstalledWindowsSdkVersions)
    if ($installedVersions.Count -eq 0) {
        return $RequestedVersion
    }

    if ($RequestedVersion -and ($installedVersions -contains $RequestedVersion)) {
        return $RequestedVersion
    }

    if ($RequestedVersion) {
        try {
            $fallback = $installedVersions | Where-Object { [version]$_ -ge [version]$RequestedVersion } | Select-Object -First 1
            if ($fallback) {
                return $fallback
            }
        } catch {
            # Ignore version parsing issues and fall back to latest installed.
        }
    }

    return $installedVersions[0]
}

function Get-VisualStudioInstallations {
    $installs = @()
    $vswhere = Get-VsWherePath

    if ($vswhere) {
        try {
            $json = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json -utf8 2>$null
            if ($json) {
                $parsed = $json | ConvertFrom-Json
                foreach ($item in @($parsed)) {
                    if (-not $item.installationPath) {
                        continue
                    }

                    $installationPath = $item.installationPath
                    $majorVersion = $null
                    if ($item.catalog -and $item.catalog.productLineVersion) {
                        $majorVersion = $item.catalog.productLineVersion
                    }
                    if (-not $majorVersion) {
                        try {
                            $majorVersion = switch (([version]$item.installationVersion).Major) {
                                16 { "2019" }
                                17 { "2022" }
                                default { $null }
                            }
                        } catch {
                            $majorVersion = $null
                        }
                    }

                    $displayName = $item.displayName
                    if (-not $displayName -and $item.catalog) {
                        $displayName = $item.catalog.productDisplayVersion
                    }

                    $edition = $null
                    if ($item.productId) {
                        $edition = ($item.productId -split '\.')[-1]
                    } elseif ($item.catalog -and $item.catalog.productLine) {
                        $edition = $item.catalog.productLine
                    }

                    $installs += [pscustomobject]@{
                        Path = $installationPath
                        Version = $item.catalog.productDisplayVersion
                        Product = $majorVersion
                        Edition = $edition
                        DisplayName = $displayName
                        InstanceId = $item.instanceId
                        VcVars = Join-Path $installationPath "VC\Auxiliary\Build\vcvars64.bat"
                    }
                }
            }
        } catch {
            Write-Info "vswhere detection failed: $($_.Exception.Message)"
        }
    }

    if (@($installs).Count -eq 0) {
        $legacyPaths = @(
            @{ Path = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community"; Product = "2019"; Edition = "Community" },
            @{ Path = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional"; Product = "2019"; Edition = "Professional" },
            @{ Path = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise"; Product = "2019"; Edition = "Enterprise" },
            @{ Path = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Community"; Product = "2022"; Edition = "Community" },
            @{ Path = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community"; Product = "2022"; Edition = "Community" },
            @{ Path = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Professional"; Product = "2022"; Edition = "Professional" },
            @{ Path = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional"; Product = "2022"; Edition = "Professional" },
            @{ Path = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Enterprise"; Product = "2022"; Edition = "Enterprise" },
            @{ Path = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise"; Product = "2022"; Edition = "Enterprise" }
        )

        foreach ($legacy in $legacyPaths) {
            if (Test-Path $legacy.Path) {
                $installs += [pscustomobject]@{
                    Path = $legacy.Path
                    Version = $legacy.Product
                    Product = $legacy.Product
                    Edition = $legacy.Edition
                    DisplayName = "Visual Studio $($legacy.Product) $($legacy.Edition)"
                    InstanceId = $legacy.Path
                    VcVars = Join-Path $legacy.Path "VC\Auxiliary\Build\vcvars64.bat"
                }
            }
        }
    }

    return @($installs | Where-Object { $_.Product -in @("2019", "2022") } | Sort-Object {
        try { [version]$_.Version } catch {
            if ($_.Product -match '^\d{4}$') { [version]"$($_.Product).0" } else { [version]"0.0" }
        }
    } -Descending)
}

function Find-VisualStudioInstallation {
    foreach ($install in (Get-VisualStudioInstallations)) {
        if (Test-Path $install.VcVars) {
            return $install
        }
    }

    return $null
}

function Import-VisualStudioEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Install
    )

    if (-not (Test-Path $Install.VcVars)) {
        $errorMsg = "Visual Studio environment script not found at '$($Install.VcVars)'"
        Write-Err $errorMsg
        throw $errorMsg
    }

    Write-Info "Using Visual Studio installation: $($Install.DisplayName)"
    Write-Info "Visual Studio path         : $($Install.Path)"
    Write-Info "Visual Studio vcvars path  : $($Install.VcVars)"

    $cmdArgs = @(
        '/c',
        "`"$($Install.VcVars)`" >nul && set"
    )

    $envOutput = & $env:COMSPEC $cmdArgs 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $errorMsg = "Failed to initialize Visual Studio build environment via '$($Install.VcVars)' (exit code: $exitCode)"
        Write-Err $errorMsg
        throw $errorMsg
    }

    foreach ($line in $envOutput) {
        $lineText = $line.ToString()
        $separatorIndex = $lineText.IndexOf('=')
        if ($separatorIndex -le 0) {
            continue
        }

        $name = $lineText.Substring(0, $separatorIndex)
        $value = $lineText.Substring($separatorIndex + 1)
        if ($name.StartsWith('=')) {
            continue
        }
        [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
    }

    $script:SelectedVisualStudio = $Install
}

# --- Resolve paths -----------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $errorMsg = "SourcePath parameter is required but was null or empty"
    Write-Err $errorMsg
    throw $errorMsg
}

if (-not (Test-Path $SourcePath)) {
    $errorMsg = "SourcePath does not exist: '$SourcePath'"
    Write-Err $errorMsg
    throw $errorMsg
}

try {
    $SourcePath = (Resolve-Path $SourcePath).ProviderPath
} catch {
    $errorMsg = "Failed to resolve SourcePath: '$SourcePath'. Error: $($_.Exception.Message)"
    Write-Err $errorMsg
    throw $errorMsg
}

$PcbuildPath = Join-Path $SourcePath "PCbuild"
$MsiToolsPath = Join-Path $SourcePath "Tools\msi"
$VenvPath = Join-Path $SourcePath $VenvName

if (-not (Test-Path $PcbuildPath)) {
    $errorMsg = "PCbuild folder not found at '$PcbuildPath'"
    Write-Err $errorMsg
    throw $errorMsg
}
if (-not (Test-Path $MsiToolsPath)) {
    $errorMsg = "Tools\msi folder not found at '$MsiToolsPath'"
    Write-Err $errorMsg
    throw $errorMsg
}
if (-not (Test-Path $BootstrapPython)) {
    $errorMsg = "Bootstrap Python not found at '$BootstrapPython'"
    Write-Err $errorMsg
    throw $errorMsg
}
if (Test-IsWindowsAppsPythonAlias -Path $BootstrapPython) {
    $errorMsg = "Bootstrap Python path '$BootstrapPython' points to the WindowsApps alias. Install Python 3.12 or 3.10 from python.org and use the real python.exe path."
    Write-Err $errorMsg
    throw $errorMsg
}
if (-not (Test-Path $VenvPath)) {
    $errorMsg = "Venv '$VenvName' not found at '$VenvPath' (create it with: python -m venv $VenvName)"
    Write-Err $errorMsg
    throw $errorMsg
}

$visualStudioInstall = Find-VisualStudioInstallation
if (-not $visualStudioInstall) {
    $errorMsg = "Visual Studio 2019/2022 with C++ build tools was not found. Install Visual Studio 2022 Professional (recommended) or a supported 2019/2022 edition with the Desktop development with C++ workload."
    Write-Err $errorMsg
    throw $errorMsg
}

Import-VisualStudioEnvironment -Install $visualStudioInstall

$resolvedWinSdkVersion = Resolve-WindowsSdkVersion -RequestedVersion $WinSdkVersion
if ($resolvedWinSdkVersion -ne $WinSdkVersion) {
    Write-Info "Requested Windows SDK '$WinSdkVersion' not found. Using '$resolvedWinSdkVersion' instead."
    $WinSdkVersion = $resolvedWinSdkVersion
}

Write-Info "Source path       : $SourcePath"
Write-Info "PCbuild path      : $PcbuildPath"
Write-Info "MSI tools path    : $MsiToolsPath"
Write-Info "Doc venv path     : $VenvPath"
Write-Info "Bootstrap Python  : $BootstrapPython"
if ($BuildId) {
    Write-Info "Build ID          : $BuildId"
}
if ($script:LogPath) {
    Write-Info "Log path          : $script:LogPath"
}

$commitHash = ""
try {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $commitHash = (& git -C $PSScriptRoot rev-parse --short HEAD 2>$null).Trim()
    }
} catch {
    $commitHash = ""
}

$bootstrapVersion = ""
try {
    $bootstrapVersion = (& $BootstrapPython --version 2>&1 | Out-String).Trim()
} catch {
    $bootstrapVersion = ""
}
if (-not $bootstrapVersion) {
    $errorMsg = "Bootstrap Python could not be executed at '$BootstrapPython'. Use a real python.exe from a python.org installation, not a WindowsApps alias."
    Write-Err $errorMsg
    throw $errorMsg
}

$msvcInfo = ""
try {
    $clCmd = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($clCmd) {
        $msvcInfo = $clCmd.Source
    }
} catch {
    $msvcInfo = ""
}

$fingerprint = @{
    BuildId = $BuildId
    StartTime = (Get-Date).ToString("o")
    SourcePath = $SourcePath
    BootstrapPython = $BootstrapPython
    BootstrapVersion = $bootstrapVersion
    WinSdkVersion = $WinSdkVersion
    MsvcToolset = $msvcInfo
    VisualStudioPath = if ($script:SelectedVisualStudio) { $script:SelectedVisualStudio.Path } else { "" }
    VisualStudioVersion = if ($script:SelectedVisualStudio) { $script:SelectedVisualStudio.Version } else { "" }
    VisualStudioProduct = if ($script:SelectedVisualStudio) { $script:SelectedVisualStudio.Product } else { "" }
    VisualStudioEdition = if ($script:SelectedVisualStudio) { $script:SelectedVisualStudio.Edition } else { "" }
    ScriptCommit = $commitHash
}
Write-Log -Level "META" -Message (($fingerprint | ConvertTo-Json -Compress))

# --- Validate venv tools ----------------------------------------------------

Write-Info "Validating documentation venv tools..."
$VenvScriptsPath = Join-Path $VenvPath "Scripts"
$VenvPythonPath = Join-Path $VenvScriptsPath "python.exe"
$SphinxBuildPath = Join-Path $VenvScriptsPath "sphinx-build.exe"
$PipPath = Join-Path $VenvScriptsPath "pip.exe"
$RequirementsPath = Join-Path $SourcePath "Doc\requirements.txt"

if (-not (Test-Path $VenvPythonPath)) {
    $errorMsg = "Venv Python not found at '$VenvPythonPath'. Recreate the venv from the UI or run 'python -m venv $VenvName' in '$SourcePath'."
    Write-Err $errorMsg
    throw $errorMsg
}

if (-not (Test-Path $PipPath)) {
    $errorMsg = "pip.exe not found at '$PipPath'. The venv may be incomplete or blocked by workstation policy."
    Write-Err $errorMsg
    throw $errorMsg
}

Write-Ok "Venv tools found."

# --- Set environment variables ----------------------------------------------

$previousPath = $env:PATH
$env:PYTHON = $BootstrapPython
$env:PATH = "$VenvScriptsPath;$previousPath"

# Check if sphinx-build exists, if not try to install requirements
if (-not (Test-Path $SphinxBuildPath)) {
    Write-Info "sphinx-build.exe not found. Attempting to install requirements..."

    if (-not (Test-Path $RequirementsPath)) {
        $errorMsg = "Doc\requirements.txt not found at '$RequirementsPath'"
        Write-Err $errorMsg
        throw $errorMsg
    }
    
    # Try to install requirements
    Write-Info "Installing requirements from Doc\requirements.txt..."
    $installArgs = @("install", "-r", $RequirementsPath)
    $proc = Start-Process -FilePath $PipPath -ArgumentList $installArgs -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        $errorMsg = "Failed to install requirements (exit code: $($proc.ExitCode)). Please run 'pip install -r Doc\requirements.txt' manually in the venv."
        Write-Err $errorMsg
        throw $errorMsg
    }
    
    # Verify sphinx-build was installed
    if (-not (Test-Path $SphinxBuildPath)) {
        $errorMsg = "sphinx-build.exe still not found after installing requirements. Please check Doc\requirements.txt"
        Write-Err $errorMsg
        throw $errorMsg
    }
    
    Write-Ok "Requirements installed successfully."
}

$env:SPHINXBUILD = $SphinxBuildPath
$env:WindowsTargetPlatformVersion = $WinSdkVersion
$env:WindowsSDKVersion = "$WinSdkVersion\"

Write-Info "Environment variables set:"
Write-Info "  PYTHON        = $($env:PYTHON)"
Write-Info "  SPHINXBUILD   = $($env:SPHINXBUILD)"
Write-Info "  WinTargetVer  = $($env:WindowsTargetPlatformVersion)"
Write-Info "  WinSDKVersion = $($env:WindowsSDKVersion)"

# --- Helper to run external commands ----------------------------------------

function Invoke-Cmd {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $null
    )

    Write-Info "Running: $Command $($Arguments -join ' ')"

    # For .bat files, run through cmd.exe to ensure proper execution
    $isBatchFile = $Command -match '\.bat$|\.cmd$'
    
    # Get the directory of the command if no working directory specified
    if (-not $WorkingDirectory -and $Command) {
        try {
            $CommandDir = Split-Path -Parent $Command
            if ($CommandDir -and (Test-Path $CommandDir)) {
                $WorkingDirectory = $CommandDir
            }
        } catch {
            # If Split-Path fails, continue without setting working directory
        }
    }
    
    if ($WorkingDirectory) {
        Write-Info "Working directory: $WorkingDirectory"
    }
    
    try {
        if ($isBatchFile) {
            # For batch files, use cmd.exe and capture output using the call operator
            # This ensures all output is captured and displayed
            Write-Info "Executing batch file through cmd.exe"
            
            $batchCmd = "cmd.exe /c `"$Command`""
            if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
                $batchCmd += " " + ($Arguments -join ' ')
            }
            
            Write-Info "Command: $batchCmd"
            
            # Change to working directory if specified
            $originalLocation = $null
            if ($WorkingDirectory) {
                $originalLocation = Get-Location
                Set-Location $WorkingDirectory
            }
            
            try {
                # Build argument list for cmd.exe
                $cmdArgs = @('/c')
                $cmdArgs += "`"$Command`""
                if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
                    $cmdArgs += $Arguments
                }
                
                # Execute batch command and capture all output.
                # Keep native stderr as log output instead of promoting warnings to terminating errors.
                $previousErrorActionPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    $output = & $env:COMSPEC $cmdArgs 2>&1
                } finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }
                
                # Check exit code using $LASTEXITCODE (more reliable than $? for native commands)
                $exitCode = $LASTEXITCODE
                
                # Display all output lines
                foreach ($line in $output) {
                    $lineStr = $line.ToString().Trim()
                    if ($lineStr) {
                        Write-Info $lineStr
                    }
                }
                
                # Check if command failed (non-zero exit code)
                if ($exitCode -ne 0) {
                    $errorMsg = "Command failed with exit code $exitCode : $Command"
                    Write-Err $errorMsg
                    throw $errorMsg
                }
                
                Write-Ok "Command completed: $Command"
                return @{
                    ExitCode = 0
                    Output = (($output | ForEach-Object { $_.ToString() }) -join "`n")
                    ErrorOutput = ""
                }
            } catch {
                Write-Err "Error executing batch file: $($_.Exception.Message)"
                throw
            } finally {
                if ($originalLocation) {
                    Set-Location $originalLocation
                }
            }
        } else {
            # For non-batch files, use the Process approach with real-time output
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = $Command
            $processInfo.UseShellExecute = $false
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $processInfo.CreateNoWindow = $true
            
            if ($WorkingDirectory) {
                $processInfo.WorkingDirectory = $WorkingDirectory
            }
            
            if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
                $processInfo.Arguments = ($Arguments | ForEach-Object { 
                    if ($_ -match '\s' -and -not $_.StartsWith('"')) { 
                        "`"$_`"" 
                    } else { 
                        $_ 
                    } 
                }) -join ' '
            }
            
            Write-Info "Command: $($processInfo.FileName) $($processInfo.Arguments)"
            
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo
            
            # Capture output in real-time
            $outputBuilder = New-Object System.Text.StringBuilder
            $errorBuilder = New-Object System.Text.StringBuilder
            
            $outputEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action {
                if ($EventArgs.Data) {
                    $line = $EventArgs.Data
                    $null = $Event.MessageData.AppendLine($line)
                    Write-Info $line
                }
            } -MessageData $outputBuilder
            
            $errorEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action {
                if ($EventArgs.Data) {
                    $line = $EventArgs.Data
                    $null = $Event.MessageData.AppendLine($line)
                    Write-Info $line
                }
            } -MessageData $errorBuilder
            
            $process.Start() | Out-Null
            $process.BeginOutputReadLine()
            $process.BeginErrorReadLine()
            
            Write-Info "Process started (PID: $($process.Id))"
            
            # Wait for process with timeout (30 minutes for build commands)
            $timeout = 1800
            $startTime = Get-Date
            while (-not $process.HasExited) {
                Start-Sleep -Milliseconds 100
                $elapsed = (Get-Date) - $startTime
                if ($elapsed.TotalSeconds -gt $timeout) {
                    $process.Kill()
                    $errorMsg = "Command timed out after $timeout seconds: $Command"
                    Write-Err $errorMsg
                    throw $errorMsg
                }
            }
            
            # Wait for async output to finish
            Start-Sleep -Milliseconds 1000
            
            # Unregister events
            Unregister-Event -SourceIdentifier $outputEvent.Name -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier $errorEvent.Name -ErrorAction SilentlyContinue
            Remove-Event -SourceIdentifier $outputEvent.Name -ErrorAction SilentlyContinue
            Remove-Event -SourceIdentifier $errorEvent.Name -ErrorAction SilentlyContinue
            
            $output = $outputBuilder.ToString()
            $errorOutput = $errorBuilder.ToString()
            
            Write-Info "Process exited with code: $($process.ExitCode)"
            
            if ($process.ExitCode -ne 0) {
                $errorMsg = "Command failed with exit code $($process.ExitCode): $Command"
                if ($errorOutput) {
                    $errorMsg += "`nError output: $errorOutput"
                }
                if ($output) {
                    $errorMsg += "`nStandard output: $output"
                }
                Write-Err $errorMsg
                throw $errorMsg
            }
            
            Write-Ok "Command completed: $Command"
            return @{
                ExitCode = $process.ExitCode
                Output = $output
                ErrorOutput = $errorOutput
            }
        }
    } catch {
        Write-Err "Error executing command: $($_.Exception.Message)"
        throw
    }
}

function Get-ExpectedDocHelpFilename {
    param([string]$SourceRoot)

    $patchlevelPath = Join-Path $SourceRoot "Include\patchlevel.h"
    if (-not (Test-Path $patchlevelPath)) {
        return $null
    }

    $content = Get-Content $patchlevelPath -Raw
    $major = ([regex]::Match($content, '#define\s+PY_MAJOR_VERSION\s+(\d+)')).Groups[1].Value
    $minor = ([regex]::Match($content, '#define\s+PY_MINOR_VERSION\s+(\d+)')).Groups[1].Value
    $micro = ([regex]::Match($content, '#define\s+PY_MICRO_VERSION\s+(\d+)')).Groups[1].Value
    $level = ([regex]::Match($content, '#define\s+PY_RELEASE_LEVEL\s+(PY_RELEASE_LEVEL_[A-Z]+)')).Groups[1].Value
    $serial = ([regex]::Match($content, '#define\s+PY_RELEASE_SERIAL\s+(\d+)')).Groups[1].Value

    if (-not $major -or -not $minor -or -not $micro) {
        return $null
    }

    $suffix = switch ($level) {
        "PY_RELEASE_LEVEL_ALPHA" { "a$serial" }
        "PY_RELEASE_LEVEL_BETA" { "b$serial" }
        "PY_RELEASE_LEVEL_GAMMA" { "rc$serial" }
        default { "" }
    }

    return "python$major$minor$micro$suffix.chm"
}

function Get-SourceVersionInfo {
    param([string]$SourceRoot)

    $patchlevelPath = Join-Path $SourceRoot "Include\patchlevel.h"
    if (-not (Test-Path $patchlevelPath)) {
        return $null
    }

    $content = Get-Content $patchlevelPath -Raw
    $major = ([regex]::Match($content, '#define\s+PY_MAJOR_VERSION\s+(\d+)')).Groups[1].Value
    $minor = ([regex]::Match($content, '#define\s+PY_MINOR_VERSION\s+(\d+)')).Groups[1].Value
    $micro = ([regex]::Match($content, '#define\s+PY_MICRO_VERSION\s+(\d+)')).Groups[1].Value
    $level = ([regex]::Match($content, '#define\s+PY_RELEASE_LEVEL\s+(PY_RELEASE_LEVEL_[A-Z]+)')).Groups[1].Value
    $serial = ([regex]::Match($content, '#define\s+PY_RELEASE_SERIAL\s+(\d+)')).Groups[1].Value

    if (-not $major -or -not $minor -or -not $micro) {
        return $null
    }

    $suffix = switch ($level) {
        "PY_RELEASE_LEVEL_ALPHA" { "a$serial" }
        "PY_RELEASE_LEVEL_BETA" { "b$serial" }
        "PY_RELEASE_LEVEL_GAMMA" { "rc$serial" }
        default { "" }
    }

    return [pscustomobject]@{
        Major = [int]$major
        Minor = [int]$minor
        Micro = [int]$micro
        Version = "$major.$minor.$micro$suffix"
        DocHelpFilename = "python$major$minor$micro$suffix.chm"
        PreferHtmlDocs = (([int]$major -gt 3) -or (([int]$major -eq 3) -and ([int]$minor -ge 11)))
    }
}

function Initialize-DocBuildCompatibility {
    param(
        [string]$VenvRoot,
        [string]$PipExecutable
    )

    $venvPython = Join-Path $VenvRoot "Scripts\python.exe"
    if (-not (Test-Path $venvPython)) {
        $errorMsg = "Venv Python not found at '$venvPython'"
        Write-Err $errorMsg
        throw $errorMsg
    }

    $pkgResourcesCheck = "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('pkg_resources') else 1)"

    try {
        & $venvPython -c $pkgResourcesCheck *> $null
        if ($LASTEXITCODE -eq 0) {
            return
        }
    } catch {
        # Continue to compatibility install below.
    }

    Write-Info "pkg_resources is missing in the doc venv. Installing a setuptools version compatible with older Sphinx..."
    $proc = Start-Process -FilePath $PipExecutable -ArgumentList @("install", "setuptools<81") -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        $errorMsg = "Failed to install compatible setuptools for documentation build (exit code: $($proc.ExitCode))."
        Write-Err $errorMsg
        throw $errorMsg
    }

    try {
        & $venvPython -c $pkgResourcesCheck *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "pkg_resources still unavailable"
        }
    } catch {
        $errorMsg = "pkg_resources is still unavailable after installing compatible setuptools."
        Write-Err $errorMsg
        throw $errorMsg
    }
}

function New-BuildReleaseDocumentation {
    param(
        [string]$SourceRoot,
        [string]$VenvRoot,
        [string]$PipExecutable
    )

    $docPath = Join-Path $SourceRoot "Doc"
    $versionInfo = Get-SourceVersionInfo -SourceRoot $SourceRoot
    if (-not $versionInfo) {
        $errorMsg = "Could not determine source version from Include\patchlevel.h."
        Write-Err $errorMsg
        throw $errorMsg
    }

    if ($versionInfo.PreferHtmlDocs) {
        $docOutputPath = Join-Path $docPath "build\html\index.html"
        if (Test-Path $docOutputPath) {
            Write-Ok "HTML documentation already available: $docOutputPath"
            return $docOutputPath
        }

        Initialize-DocBuildCompatibility -VenvRoot $VenvRoot -PipExecutable $PipExecutable

        Write-Step "Step 3.5/4: Building HTML documentation for MSI packaging..."
        Invoke-Cmd -Command "$docPath\make.bat" -Arguments @("html") -WorkingDirectory $docPath

        if (-not (Test-Path $docOutputPath)) {
            $errorMsg = "Expected HTML documentation was not created: '$docOutputPath'"
            Write-Err $errorMsg
            throw $errorMsg
        }

        Write-Ok "HTML documentation created: $docOutputPath"
        return $docOutputPath
    }

    $hhcPath = Join-Path $SourceRoot "externals\windows-installer\htmlhelp\hhc.exe"
    $docFilename = $versionInfo.DocHelpFilename
    if (-not $docFilename) {
        $errorMsg = "Could not determine expected CHM documentation filename from Include\patchlevel.h."
        Write-Err $errorMsg
        throw $errorMsg
    }

    $docOutputPath = Join-Path $docPath "build\htmlhelp\$docFilename"
    if (Test-Path $docOutputPath) {
        Write-Ok "Compiled HTML Help already available: $docOutputPath"
        return $docOutputPath
    }

    if (-not (Test-Path $hhcPath)) {
        $errorMsg = "HTML Help compiler not found at '$hhcPath'. Run Tools\\msi\\get_externals.bat or verify the htmlhelp external package."
        Write-Err $errorMsg
        throw $errorMsg
    }

    Initialize-DocBuildCompatibility -VenvRoot $VenvRoot -PipExecutable $PipExecutable

    Write-Step "Step 3.5/4: Building compiled HTML Help documentation..."
    $previousHtmlHelp = $env:HTMLHELP
    $env:HTMLHELP = $hhcPath
    try {
        Invoke-Cmd -Command "$docPath\make.bat" -Arguments @("htmlhelp") -WorkingDirectory $docPath
    } finally {
        $env:HTMLHELP = $previousHtmlHelp
    }

    if (-not (Test-Path $docOutputPath)) {
        $errorMsg = "Expected compiled documentation was not created: '$docOutputPath'"
        Write-Err $errorMsg
        throw $errorMsg
    }

    Write-Ok "Compiled HTML Help created: $docOutputPath"
    return $docOutputPath
}

function Invoke-BuildEvidenceCapture {
    param(
        [string]$SourceRoot,
        [string]$ReleaseRootPath,
        [string]$ResolvedReleaseDir,
        [string]$BootstrapPythonPath,
        [string]$DocumentationVenvName,
        [bool]$StopOnError
    )

    $evidenceScriptPath = Join-Path $PSScriptRoot "Capture-BuildEvidence.ps1"
    if (-not (Test-Path $evidenceScriptPath)) {
        $message = "Evidence script not found at '$evidenceScriptPath'."
        if ($StopOnError) {
            Write-Err $message
            throw $message
        }

        Write-Info $message
        return
    }

    Write-Step "Capturing build evidence..."
    Write-Info "Evidence script : $evidenceScriptPath"

    try {
        & $evidenceScriptPath `
            -SourcePath $SourceRoot `
            -ReleaseRoot $ReleaseRootPath `
            -ReleaseDir $ResolvedReleaseDir `
            -BootstrapPython $BootstrapPythonPath `
            -VenvName $DocumentationVenvName

        if ($LASTEXITCODE -ne 0) {
            throw "Capture-BuildEvidence.ps1 exited with code $LASTEXITCODE."
        }

        $evidenceDir = Join-Path $ResolvedReleaseDir "_evidence"
        Write-Ok "Build evidence captured: $evidenceDir"
    } catch {
        $message = "Build evidence capture failed: $($_.Exception.Message)"
        if ($StopOnError) {
            Write-Err $message
            throw $message
        }

        Write-Info $message
    }
}

# --- Step 1: PCbuild\get_externals ------------------------------------------

Write-Info "=== Starting Step 1: PCbuild\get_externals ==="
Write-Step "Step 1/4: Downloading PCbuild externals..."
Write-Info "Command will be: $PcbuildPath\get_externals.bat"
Write-Info "Working directory: $PcbuildPath"

try {
    Invoke-Cmd -Command "$PcbuildPath\get_externals.bat" -Arguments @() -WorkingDirectory $PcbuildPath
    Write-Info "=== Step 1 completed ==="
} catch {
    Write-Err "Step 1 failed: $($_.Exception.Message)"
    throw
}

# --- Step 2: build.bat -p x64 --pgo -----------------------------------------

Write-Step "Step 2/4: Building CPython binaries (this may take a while)..."
Invoke-Cmd -Command "$PcbuildPath\build.bat" -Arguments @("-p","x64","--pgo") -WorkingDirectory $PcbuildPath

# --- Step 3: Tools\msi\get_externals ----------------------------------------

Write-Step "Step 3/4: Downloading MSI externals..."
Invoke-Cmd -Command "$MsiToolsPath\get_externals.bat" -Arguments @() -WorkingDirectory $MsiToolsPath

New-BuildReleaseDocumentation -SourceRoot $SourcePath -VenvRoot $VenvPath -PipExecutable $PipPath | Out-Null

# --- Step 4: Tools\msi\buildrelease.bat -x64 --------------------------------

Write-Step "Step 4/4: Building Windows installer..."
$msiBuildResult = Invoke-Cmd -Command "$MsiToolsPath\buildrelease.bat" -Arguments @("-x64", "--skip-doc") -WorkingDirectory $SourcePath
$msiBuildOutput = "$($msiBuildResult.Output)`n$($msiBuildResult.ErrorOutput)"
if ($msiBuildOutput -match '(?im)^\s*Build FAILED\.' -or $msiBuildOutput -match '(?im):\s*error\s+[A-Z]{3}\d{4}\s*:') {
    $errorMsg = "MSI build reported failure output even though buildrelease.bat returned success. Check log output from Step 4 for details."
    Write-Err $errorMsg
    throw $errorMsg
}

# --- Step 5: Collect artefacts ----------------------------------------------

Write-Step "Collecting build artefacts..."
$OutDir = Join-Path $PcbuildPath "amd64\en-us"
if (-not (Test-Path $OutDir)) {
    $errorMsg = "Expected output directory not found: '$OutDir'"
    Write-Err $errorMsg
    throw $errorMsg
}

$pythonVersion = ""
$versionCandidates = @(
    (Join-Path $PcbuildPath "python.exe"),
    (Join-Path $PcbuildPath "amd64\python.exe"),
    (Join-Path $PcbuildPath "amd64\instrumented\python.exe")
)

try {
    foreach ($versionFile in $versionCandidates) {
        if (-not (Test-Path $versionFile)) {
            continue
        }

        $out = & $versionFile -V 2>$null
        if ($out) {
            $pythonVersion = $out.Trim()
            break
        }
    }
} catch {
    $pythonVersion = ""
}

if (-not $pythonVersion) {
    $sourceLeaf = Split-Path -Leaf $SourcePath
    if ($sourceLeaf -match '^Python-(\d+\.\d+\.\d+)$') {
        $pythonVersion = "Python $($matches[1])"
    }
}

if (-not (Test-Path $ReleaseRoot)) {
    New-Item -ItemType Directory -Path $ReleaseRoot | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$releaseBaseName = if ($pythonVersion -match '^Python\s+(\d+\.\d+\.\d+)') {
    "Python-$($matches[1])"
} else {
    "PythonRelease"
}
$releaseName = "${releaseBaseName}_$stamp"
$ReleaseDir = Join-Path $ReleaseRoot $releaseName

New-Item -ItemType Directory -Path $ReleaseDir | Out-Null

Write-Info "Copying artefacts from '$OutDir' to '$ReleaseDir'..."
Copy-Item -Path (Join-Path $OutDir "*") -Destination $ReleaseDir -Recurse
Write-Ok "Artefacts copied."

# --- Optional: zip everything -----------------------------------------------

$zipPath = Join-Path $ReleaseRoot "$releaseName.zip"
Write-Info "Creating zip: $zipPath"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $ReleaseDir "*") -DestinationPath $zipPath
Write-Ok "Zip created."

if ($CaptureEvidence) {
    Invoke-BuildEvidenceCapture `
        -SourceRoot $SourcePath `
        -ReleaseRootPath $ReleaseRoot `
        -ResolvedReleaseDir $ReleaseDir `
        -BootstrapPythonPath $BootstrapPython `
        -DocumentationVenvName $VenvName `
        -StopOnError $FailOnEvidenceError
}

Write-Host ""
Write-Ok "Build pipeline completed successfully."
Write-Info "Release folder : $ReleaseDir"
Write-Info "Release zip    : $zipPath"
if ($pythonVersion) {
    Write-Info "Built Python   : $pythonVersion"
}
$duration = (Get-Date) - $script:BuildStart
$successMeta = @{
    result = "success"
    durationSeconds = [int]$duration.TotalSeconds
} | ConvertTo-Json -Compress
Write-Log -Level "META" -Message $successMeta

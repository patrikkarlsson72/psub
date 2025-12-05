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
    [scriptblock]$ProgressCallback = $null
)

$ErrorActionPreference = "Continue"
$script:BuildError = $null

function Write-Info($msg) {
    Write-Host "[INFO ] $msg" -ForegroundColor Cyan
    if ($ProgressCallback) {
        & $ProgressCallback "info" $msg
    }
}

function Write-Ok($msg) {
    Write-Host "[ OK  ] $msg" -ForegroundColor Green
    if ($ProgressCallback) {
        & $ProgressCallback "ok" $msg
    }
}

function Write-Err($msg) {
    Write-Host "[FAIL] $msg" -ForegroundColor Red
    Write-Error $msg -ErrorAction Continue
    if ($ProgressCallback) {
        & $ProgressCallback "error" $msg
    }
    $script:BuildError = $msg
}

function Write-Step($msg) {
    Write-Host "[STEP ] $msg" -ForegroundColor Yellow
    if ($ProgressCallback) {
        & $ProgressCallback "step" $msg
    }
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
if (-not (Test-Path $VenvPath)) {
    $errorMsg = "Venv '$VenvName' not found at '$VenvPath' (create it with: python -m venv $VenvName)"
    Write-Err $errorMsg
    throw $errorMsg
}

Write-Info "Source path       : $SourcePath"
Write-Info "PCbuild path      : $PcbuildPath"
Write-Info "MSI tools path    : $MsiToolsPath"
Write-Info "Doc venv path     : $VenvPath"
Write-Info "Bootstrap Python  : $BootstrapPython"

# --- Activate venv -----------------------------------------------------------

Write-Info "Checking venv activation script..."
$ActivateScript = Join-Path $VenvPath "Scripts\Activate.ps1"
Write-Info "Activate script path: $ActivateScript"

if (-not (Test-Path $ActivateScript)) {
    $errorMsg = "Cannot find venv activate script at '$ActivateScript'"
    Write-Err $errorMsg
    throw $errorMsg
}

Write-Info "Activating venv..."
try {
    . $ActivateScript
    Write-Ok "Venv activated."
} catch {
    $errorMsg = "Failed to activate venv: $($_.Exception.Message)"
    Write-Err $errorMsg
    throw $errorMsg
}

# --- Set environment variables ----------------------------------------------

$env:PYTHON = $BootstrapPython
$SphinxBuildPath = Join-Path $VenvPath "Scripts\sphinx-build.exe"
$PipPath = Join-Path $VenvPath "Scripts\pip.exe"
$RequirementsPath = Join-Path $SourcePath "Doc\requirements.txt"

# Check if sphinx-build exists, if not try to install requirements
if (-not (Test-Path $SphinxBuildPath)) {
    Write-Info "sphinx-build.exe not found. Attempting to install requirements..."
    
    if (-not (Test-Path $PipPath)) {
        $errorMsg = "pip.exe not found at '$PipPath'. Venv may be corrupted."
        Write-Err $errorMsg
        throw $errorMsg
    }
    
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
                
                # Execute using call operator with output redirection
                # This allows real-time output display
                $output = & $env:COMSPEC $cmdArgs 2>&1
                
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
        }
    } catch {
        Write-Err "Error executing command: $($_.Exception.Message)"
        throw
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

# --- Step 4: Tools\msi\buildrelease.bat -x64 --------------------------------

Write-Step "Step 4/4: Building Windows installer..."
Invoke-Cmd -Command "$MsiToolsPath\buildrelease.bat" -Arguments @("-x64") -WorkingDirectory $SourcePath

# --- Step 5: Collect artefacts ----------------------------------------------

Write-Step "Collecting build artefacts..."
$OutDir = Join-Path $PcbuildPath "amd64\en-us"
if (-not (Test-Path $OutDir)) {
    $errorMsg = "Expected output directory not found: '$OutDir'"
    Write-Err $errorMsg
    throw $errorMsg
}

$versionFile = Join-Path $PcbuildPath "python.exe"
$pythonVersion = ""

try {
    if (Test-Path $versionFile) {
        $out = & $versionFile -V 2>$null
        $pythonVersion = $out.Trim()
    }
} catch {
    $pythonVersion = ""
}

if (-not (Test-Path $ReleaseRoot)) {
    New-Item -ItemType Directory -Path $ReleaseRoot | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$releaseName = "PythonRelease_$stamp"
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

Write-Host ""
Write-Ok "Build pipeline completed successfully."
Write-Info "Release folder : $ReleaseDir"
Write-Info "Release zip    : $zipPath"
if ($pythonVersion) {
    Write-Info "Built Python   : $pythonVersion"
}

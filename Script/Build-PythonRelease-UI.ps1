#requires -Version 5.1

<#
.SYNOPSIS
    Web-based UI for building Python security releases on Windows.

.DESCRIPTION
    Starts a local web server that provides a clean interface for building
    Python 3.10/3.11/3.12 security releases. Includes prerequisite validation,
    path auto-detection, and real-time build progress.

.PARAMETER Port
    Port number for the web server (default: 8080)

.PARAMETER BuildScriptPath
    Path to Build-PythonRelease.ps1 script (default: same directory)

.EXAMPLE
    .\Build-PythonRelease-UI.ps1
    Starts the web UI on http://localhost:8080
#>

param(
    [int]$Port = 8080,
    [string]$BuildScriptPath = (Join-Path $PSScriptRoot "Build-PythonRelease.ps1")
)

$ErrorActionPreference = "Stop"

# Global state for build process
$script:BuildJob = $null
$script:ProgressEvents = [System.Collections.ArrayList]::new()
$script:ProgressLock = [System.Threading.ReaderWriterLockSlim]::new()

# --- Helper Functions ---------------------------------------------------------

function Write-Info($msg) {
    Write-Host "[INFO] $msg" -ForegroundColor Cyan
}

function Write-Err($msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
}

function Write-Ok($msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}

# --- Prerequisite Checking Functions -----------------------------------------

function Test-VisualStudio2019 {
    $vsPaths = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise"
    )
    
    foreach ($path in $vsPaths) {
        if (Test-Path $path) {
            return @{
                Installed = $true
                Path = $path
            }
        }
    }
    
    return @{ Installed = $false }
}

function Test-MSVCToolchains {
    $required = @("x64", "x86", "ARM64", "ARM64EC")
    $found = @()
    $missing = @()
    
    $vcToolsPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\*\VC\Tools\MSVC"
    $toolchainDirs = Get-ChildItem -Path $vcToolsPath -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.\d+$' }
    
    if ($toolchainDirs) {
        $latestToolchain = $toolchainDirs | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
        $binPath = Join-Path $latestToolchain.FullName "bin\Hostx64"
        
        foreach ($arch in $required) {
            $archPath = Join-Path $binPath "x64"
            if ($arch -eq "x86") { $archPath = Join-Path $binPath "x86" }
            if ($arch -eq "ARM64") { $archPath = Join-Path $binPath "arm64" }
            if ($arch -eq "ARM64EC") { $archPath = Join-Path $binPath "arm64ec" }
            
            $clPath = Join-Path $archPath "cl.exe"
            if (Test-Path $clPath) {
                $found += $arch
            } else {
                $missing += $arch
            }
        }
    }
    
    return @{
        Found = $found
        Missing = $missing
        AllPresent = ($missing.Count -eq 0)
    }
}

function Test-WindowsSDK {
    $requiredVersion = "10.0.19041.0"
    $sdkPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Include"
    
    if (Test-Path $sdkPath) {
        $versions = Get-ChildItem -Path $sdkPath -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' }
        $found = $versions | Where-Object { $_.Name -eq $requiredVersion }
        
        return @{
            Installed = ($null -ne $found)
            Version = if ($found) { $found.Name } else { $null }
            AvailableVersions = $versions | ForEach-Object { $_.Name }
        }
    }
    
    return @{ Installed = $false }
}

function Find-BootstrapPython {
    $searchPaths = @(
        "${env:ProgramFiles}\Python*",
        "${env:ProgramFiles(x86)}\Python*",
        "${env:LOCALAPPDATA}\Programs\Python\Python*",
        "$env:USERPROFILE\AppData\Local\Programs\Python\Python*"
    )
    
    $found = @()
    
    foreach ($pattern in $searchPaths) {
        $dirs = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue -Directory
        foreach ($dir in $dirs) {
            $pythonExe = Join-Path $dir.FullName "python.exe"
            if (Test-Path $pythonExe) {
                try {
                    $version = & $pythonExe --version 2>&1
                    if ($version -match 'Python (\d+)\.(\d+)') {
                        $major = [int]$matches[1]
                        $minor = [int]$matches[2]
                        # Accept 3.10 or 3.12, not 3.13
                        if (($major -eq 3) -and (($minor -eq 10) -or ($minor -eq 12))) {
                            $found += @{
                                Path = $pythonExe
                                Version = $version.Trim()
                                Major = $major
                                Minor = $minor
                            }
                        }
                    }
                } catch {
                    # Skip if can't get version
                }
            }
        }
    }
    
    # Sort by version (prefer 3.12, then 3.10)
    $found = $found | Sort-Object { $_.Minor } -Descending
    
    return $found
}

function Test-CPythonSource {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        return @{ Valid = $false; Error = "Path does not exist" }
    }
    
    $pcbuild = Join-Path $Path "PCbuild"
    $msiTools = Join-Path $Path "Tools\msi"
    $doc = Join-Path $Path "Doc"
    
    $errors = @()
    if (-not (Test-Path $pcbuild)) { $errors += "PCbuild folder not found" }
    if (-not (Test-Path $msiTools)) { $errors += "Tools\msi folder not found" }
    if (-not (Test-Path $doc)) { $errors += "Doc folder not found" }
    
    $requirements = Join-Path $doc "requirements.txt"
    if (-not (Test-Path $requirements)) { $errors += "Doc\requirements.txt not found" }
    
    return @{
        Valid = ($errors.Count -eq 0)
        Errors = $errors
        Path = $Path
    }
}

# --- Path Auto-Detection -----------------------------------------------------

function Get-DetectedPaths {
    $python = Find-BootstrapPython
    $vs = Test-VisualStudio2019
    $sdk = Test-WindowsSDK
    
    return @{
        Python = if ($python.Count -gt 0) { $python[0].Path } else { $null }
        PythonVersions = $python
        VisualStudio = if ($vs.Installed) { $vs.Path } else { $null }
        WindowsSDK = if ($sdk.Installed) { $sdk.Version } else { $null }
    }
}

# --- Venv Setup Functions -----------------------------------------------------

function New-DocumentationVenv {
    param(
        [string]$SourcePath,
        [string]$VenvName = "doc-venv",
        [string]$BootstrapPython
    )
    
    $venvPath = Join-Path $SourcePath $VenvName
    $requirementsPath = Join-Path $SourcePath "Doc\requirements.txt"
    $pipPath = Join-Path $venvPath "Scripts\pip.exe"
    
    if (-not (Test-Path $requirementsPath)) {
        return @{ Success = $false; Error = "Doc\requirements.txt not found" }
    }
    
    try {
        # Check if venv already exists
        if (Test-Path $venvPath) {
            # Venv exists - just install/update requirements
            if (-not (Test-Path $pipPath)) {
                return @{ Success = $false; Error = "Venv exists but pip.exe not found. Venv may be corrupted." }
            }
            
            Add-ProgressEvent -Type "info" -Message "Venv already exists. Installing/updating requirements..."
            $installArgs = @("install", "-r", $requirementsPath, "--upgrade")
            $proc = Start-Process -FilePath $pipPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                return @{ Success = $false; Error = "Failed to install requirements (exit code: $($proc.ExitCode))" }
            }
            
            return @{ Success = $true; VenvPath = $venvPath; Message = "Requirements updated in existing venv" }
        } else {
            # Create new venv
            Add-ProgressEvent -Type "info" -Message "Creating new virtual environment..."
            $createArgs = @("-m", "venv", $venvPath)
            $proc = Start-Process -FilePath $BootstrapPython -ArgumentList $createArgs -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                return @{ Success = $false; Error = "Failed to create venv (exit code: $($proc.ExitCode))" }
            }
            
            # Install requirements
            if (-not (Test-Path $pipPath)) {
                return @{ Success = $false; Error = "pip.exe not found after venv creation" }
            }
            
            Add-ProgressEvent -Type "info" -Message "Installing requirements..."
            $installArgs = @("install", "-r", $requirementsPath)
            $proc = Start-Process -FilePath $pipPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                return @{ Success = $false; Error = "Failed to install requirements (exit code: $($proc.ExitCode))" }
            }
            
            return @{ Success = $true; VenvPath = $venvPath; Message = "Virtual environment created successfully" }
        }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# --- HTTP Server Functions ---------------------------------------------------

function Send-JsonResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [object]$Data,
        [int]$StatusCode = 200
    )
    
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = "application/json"
    $response.ContentLength64 = $buffer.Length
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Close()
}

function Send-TextResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$Text,
        [string]$ContentType = "text/plain",
        [int]$StatusCode = 200
    )
    
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Text)
    
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    
    # Ensure charset is specified for text content types
    if ($ContentType -match "^text/") {
        if ($ContentType -notmatch "charset=") {
            $ContentType = $ContentType + "; charset=utf-8"
        }
    }
    
    $response.ContentType = $ContentType
    $response.ContentLength64 = $buffer.Length
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Close()
}

function Get-RequestBody {
    param([System.Net.HttpListenerContext]$Context)
    
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
    $body = $reader.ReadToEnd()
    $reader.Close()
    return $body
}

function Add-ProgressEvent {
    param(
        [string]$Type,
        [string]$Message
    )
    
    $script:ProgressLock.EnterWriteLock()
    try {
        $progressEvent = @{
            Type = $Type
            Message = $Message
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
        $script:ProgressEvents.Add($progressEvent) | Out-Null
        
        # Keep only last 1000 events
        if ($script:ProgressEvents.Count -gt 1000) {
            $script:ProgressEvents.RemoveAt(0)
        }
    } finally {
        $script:ProgressLock.ExitWriteLock()
    }
}

function Get-ProgressEvents {
    param([int]$SinceIndex = 0)
    
    $script:ProgressLock.EnterReadLock()
    try {
        if ($SinceIndex -ge $script:ProgressEvents.Count) {
            return @()
        }
        return $script:ProgressEvents[$SinceIndex..($script:ProgressEvents.Count - 1)]
    } finally {
        $script:ProgressLock.ExitReadLock()
    }
}

# --- API Endpoint Handlers ---------------------------------------------------

function Invoke-PrerequisitesHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    $vs = Test-VisualStudio2019
    $toolchains = Test-MSVCToolchains
    $sdk = Test-WindowsSDK
    $python = Find-BootstrapPython
    
    $result = @{
        VisualStudio = @{
            Installed = $vs.Installed
            Path = if ($vs.Installed) { $vs.Path } else { $null }
        }
        MSVCToolchains = @{
            AllPresent = $toolchains.AllPresent
            Found = $toolchains.Found
            Missing = $toolchains.Missing
        }
        WindowsSDK = @{
            Installed = $sdk.Installed
            Version = $sdk.Version
            RequiredVersion = "10.0.19041.0"
            AvailableVersions = $sdk.AvailableVersions
        }
        BootstrapPython = @{
            Found = ($python.Count -gt 0)
            Versions = $python | ForEach-Object { @{ Path = $_.Path; Version = $_.Version } }
        }
        AllReady = ($vs.Installed -and $toolchains.AllPresent -and $sdk.Installed -and ($python.Count -gt 0))
    }
    
    Send-JsonResponse -Context $Context -Data $result
}

function Invoke-DetectPathsHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    $paths = Get-DetectedPaths
    Send-JsonResponse -Context $Context -Data $paths
}

function Invoke-ValidateSourceHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    $body = Get-RequestBody -Context $Context
    $data = $body | ConvertFrom-Json
    
    if (-not $data.SourcePath) {
        Send-JsonResponse -Context $Context -Data @{ Valid = $false; Error = "SourcePath is required" } -StatusCode 400
        return
    }
    
    $result = Test-CPythonSource -Path $data.SourcePath
    Send-JsonResponse -Context $Context -Data $result
}

function Invoke-SetupVenvHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    $body = Get-RequestBody -Context $Context
    $data = $body | ConvertFrom-Json
    
    if (-not $data.SourcePath -or -not $data.BootstrapPython) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "SourcePath and BootstrapPython are required" } -StatusCode 400
        return
    }
    
    Add-ProgressEvent -Type "info" -Message "Creating documentation virtual environment..."
    $result = New-DocumentationVenv -SourcePath $data.SourcePath -VenvName $data.VenvName -BootstrapPython $data.BootstrapPython
    
    if ($result.Success) {
        $message = if ($result.Message) { $result.Message } else { "Virtual environment ready" }
        Add-ProgressEvent -Type "ok" -Message $message
    } else {
        Add-ProgressEvent -Type "error" -Message "Failed to setup venv: $($result.Error)"
    }
    
    Send-JsonResponse -Context $Context -Data $result
}

function Invoke-BuildHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    if ($script:BuildJob -and -not $script:BuildJob.HasExited) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "Build is already in progress" } -StatusCode 409
        return
    }
    
    $body = Get-RequestBody -Context $Context
    $data = $body | ConvertFrom-Json
    
    # Validate required parameters
    if ([string]::IsNullOrWhiteSpace($data.SourcePath)) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "SourcePath is required" } -StatusCode 400
        return
    }
    if ([string]::IsNullOrWhiteSpace($data.BootstrapPython)) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "BootstrapPython is required" } -StatusCode 400
        return
    }
    
    # Clear previous progress
    $script:ProgressLock.EnterWriteLock()
    try {
        $script:ProgressEvents.Clear()
    } finally {
        $script:ProgressLock.ExitWriteLock()
    }
    
    Add-ProgressEvent -Type "info" -Message "Starting build process..."
    Add-ProgressEvent -Type "info" -Message "SourcePath: $($data.SourcePath)"
    Add-ProgressEvent -Type "info" -Message "BootstrapPython: $($data.BootstrapPython)"
    
    # SIMPLIFIED APPROACH: Create a single batch file that does everything
    # No complex wrappers, just one batch file with output redirection
    
    $buildScript = $BuildScriptPath
    
    # Find Visual Studio vcvars64.bat
    $vcvarsPath = $null
    $vsPaths = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise"
    )
    
    foreach ($vsPath in $vsPaths) {
        $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $vcvars) {
            $vcvarsPath = $vcvars
            break
        }
    }
    
    if (-not $vcvarsPath) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "Visual Studio 2019 vcvars64.bat not found. Please ensure VS 2019 is installed." } -StatusCode 400
        return
    }
    
    # Create output file for the build
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outputFile = Join-Path $env:TEMP "python-build-output-$timestamp.txt"
    $statusFile = Join-Path $env:TEMP "python-build-status-$timestamp.txt"
    
    Add-ProgressEvent -Type "info" -Message "Output file: $outputFile"
    Add-ProgressEvent -Type "info" -Message "Status file: $statusFile"
    
    # Create single batch file that does everything
    $batchFile = Join-Path $env:TEMP "python-build-$timestamp.bat"
    
    $batchContent = @"
@echo off
echo Build started at %TIME% > "$outputFile"
echo. >> "$outputFile"

echo Setting up Visual Studio environment... >> "$outputFile"
call "$vcvarsPath" >> "$outputFile" 2>&1
if errorlevel 1 (
    echo ERROR: Failed to set up Visual Studio environment >> "$outputFile"
    echo failed > "$statusFile"
    exit /b 1
)

echo. >> "$outputFile"
echo Visual Studio environment ready >> "$outputFile"
echo. >> "$outputFile"
echo Starting Python build... >> "$outputFile"
echo. >> "$outputFile"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$buildScript' -SourcePath '$($data.SourcePath)' -BootstrapPython '$($data.BootstrapPython)' -VenvName '$($data.VenvName)' -ReleaseRoot '$($data.ReleaseRoot)' -WinSdkVersion '$($data.WinSdkVersion)'" >> "$outputFile" 2>&1

if errorlevel 1 (
    echo. >> "$outputFile"
    echo BUILD FAILED >> "$outputFile"
    echo failed > "$statusFile"
    exit /b 1
) else (
    echo. >> "$outputFile"
    echo BUILD SUCCEEDED >> "$outputFile"
    echo success > "$statusFile"
    exit /b 0
)
"@
    
    Set-Content -Path $batchFile -Value $batchContent -Encoding ASCII
    
    Add-ProgressEvent -Type "info" -Message "Starting build..."
    Add-ProgressEvent -Type "info" -Message "Batch file: $batchFile"
    
    # Start the batch file
    $script:BuildJob = Start-Process -FilePath "cmd.exe" `
        -ArgumentList @("/c", "`"$batchFile`"") `
        -NoNewWindow `
        -PassThru
    
    # Store build info
    $script:BuildInfo = @{
        Process = $script:BuildJob
        OutputFile = $outputFile
        StatusFile = $statusFile
        BatchFile = $batchFile
        StartTime = Get-Date
        LastOutputSize = 0
    }
    
    # Start a monitoring job that polls the output file
    $monitorScript = {
        param($BuildInfo, $ProgressEvents, $ProgressLock)
        
        $lastOutputSize = 0
        
        while ($true) {
            Start-Sleep -Milliseconds 1000
            
            # Read new output from file
            if (Test-Path $BuildInfo.OutputFile) {
                try {
                    $fileInfo = Get-Item $BuildInfo.OutputFile -ErrorAction SilentlyContinue
                    if ($fileInfo -and $fileInfo.Length -gt $lastOutputSize) {
                        # Read new content
                        $allContent = Get-Content -Path $BuildInfo.OutputFile -Raw -ErrorAction SilentlyContinue
                        if ($allContent.Length -gt $lastOutputSize) {
                            $newContent = $allContent.Substring($lastOutputSize)
                            $lastOutputSize = $allContent.Length
                            
                            # Split into lines and add as events
                            $lines = $newContent -split "`r?`n"
                            $ProgressLock.EnterWriteLock()
                            try {
                                foreach ($line in $lines) {
                                    $trimmed = $line.Trim()
                                    if ($trimmed) {
                                        # Determine event type based on content
                                        $eventType = "info"
                                        if ($trimmed -match '\[.*OK.*\]|succeeded|completed successfully') {
                                            $eventType = "ok"
                                        } elseif ($trimmed -match '\[.*FAIL.*\]|error|failed|ERROR|FAILED') {
                                            $eventType = "error"
                                        } elseif ($trimmed -match '\[.*STEP.*\]|Step \d+') {
                                            $eventType = "step"
                                        }
                                        
                                        $ProgressEvents.Add(@{
                                            Type = $eventType
                                            Message = $trimmed
                                            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                                        }) | Out-Null
                                    }
                                }
                            } finally {
                                $ProgressLock.ExitWriteLock()
                            }
                        }
                    }
                } catch {
                    # File might be locked, ignore
                }
            }
            
            # Check if process has exited
            if ($BuildInfo.Process.HasExited) {
                Start-Sleep -Milliseconds 2000  # Give file time to be written
                
                # Read any remaining output
                if (Test-Path $BuildInfo.OutputFile) {
                    try {
                        $allContent = Get-Content -Path $BuildInfo.OutputFile -Raw -ErrorAction SilentlyContinue
                        if ($allContent.Length -gt $lastOutputSize) {
                            $newContent = $allContent.Substring($lastOutputSize)
                            $lines = $newContent -split "`r?`n"
                            $ProgressLock.EnterWriteLock()
                            try {
                                foreach ($line in $lines) {
                                    $trimmed = $line.Trim()
                                    if ($trimmed) {
                                        $eventType = "info"
                                        if ($trimmed -match '\[.*OK.*\]|succeeded|completed successfully|BUILD SUCCEEDED') {
                                            $eventType = "ok"
                                        } elseif ($trimmed -match '\[.*FAIL.*\]|error|failed|ERROR|FAILED|BUILD FAILED') {
                                            $eventType = "error"
                                        }
                                        
                                        $ProgressEvents.Add(@{
                                            Type = $eventType
                                            Message = $trimmed
                                            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                                        }) | Out-Null
                                    }
                                }
                            } finally {
                                $ProgressLock.ExitWriteLock()
                            }
                        }
                    } catch {
                        # Ignore
                    }
                }
                
                # Read final status
                $status = "unknown"
                if (Test-Path $BuildInfo.StatusFile) {
                    $status = Get-Content -Path $BuildInfo.StatusFile -Raw -ErrorAction SilentlyContinue
                    $status = $status.Trim()
                }
                
                # Add completion event
                $ProgressLock.EnterWriteLock()
                try {
                    if ($status -eq "success") {
                        $ProgressEvents.Add(@{
                            Type = "complete"
                            Success = $true
                            Message = "Build completed successfully!"
                        }) | Out-Null
                    } else {
                        $ProgressEvents.Add(@{
                            Type = "complete"
                            Success = $false
                            Message = "Build failed. Check output for details."
                        }) | Out-Null
                    }
                } finally {
                    $ProgressLock.ExitWriteLock()
                }
                
                break
            }
        }
    }
    
    Start-Job -ScriptBlock $monitorScript -ArgumentList $script:BuildInfo, $script:ProgressEvents, $script:ProgressLock | Out-Null
    
    Send-JsonResponse -Context $Context -Data @{ Success = $true; ProcessId = $script:BuildJob.Id }
}

function Invoke-ProgressHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    $sinceIndex = 0
    if ($Context.Request.QueryString["since"]) {
        [int]::TryParse($Context.Request.QueryString["since"], [ref]$sinceIndex) | Out-Null
    }
    
    $response = $Context.Response
    $response.StatusCode = 200
    $response.ContentType = "text/event-stream"
    $response.Headers.Add("Cache-Control", "no-cache")
    $response.Headers.Add("Connection", "keep-alive")
    $response.Headers.Add("Access-Control-Allow-Origin", "*")
    
    $writer = New-Object System.IO.StreamWriter($response.OutputStream, [System.Text.Encoding]::UTF8)
    
    # Send initial connection message
    $writer.WriteLine(": connected")
    $writer.Flush()
    
    $lastIndex = $sinceIndex
    $timeout = 0
    
    while ($true) {
        Start-Sleep -Milliseconds 500
        
        $events = Get-ProgressEvents -SinceIndex $lastIndex
        
        foreach ($progressEvent in $events) {
            $json = $progressEvent | ConvertTo-Json -Compress
            $writer.WriteLine("data: $json")
            $writer.WriteLine()
            $writer.Flush()
            $lastIndex++
        }
        
        # Send heartbeat every 30 seconds
        $timeout++
        if ($timeout -ge 60) {
            $writer.WriteLine(": heartbeat")
            $writer.Flush()
            $timeout = 0
        }
        
        # Check if client disconnected
        if (-not $response.OutputStream.CanWrite) {
            break
        }
        
        # Check if there's a completion event
        $hasCompleteEvent = $false
        foreach ($progressEvent in (Get-ProgressEvents -SinceIndex 0)) {
            if ($progressEvent.Type -eq "complete") {
                $hasCompleteEvent = $true
                break
            }
        }
        
        # Stop if build is complete
        if ($hasCompleteEvent) {
            # Send final events
            $finalEvents = Get-ProgressEvents -SinceIndex $lastIndex
            foreach ($progressEvent in $finalEvents) {
                $json = $progressEvent | ConvertTo-Json -Compress
                $writer.WriteLine("data: $json")
                $writer.WriteLine()
                $writer.Flush()
                $lastIndex++
            }
            
            break
        }
    }
    
    $writer.Close()
    $response.OutputStream.Close()
}

function Invoke-RootHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    $html = Get-HtmlUI
    Send-TextResponse -Context $Context -Text $html -ContentType "text/html"
}

# --- HTML UI Content ---------------------------------------------------------

function Get-HtmlUI {
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Python Build Release</title>
    <style>
        :root {
            /* Light theme (default) */
            --bg-body: linear-gradient(135deg, #e8f4f8 0%, #d0e8f2 100%);
            --bg-header: linear-gradient(135deg, #3776ab 0%, #4a90c2 100%);
            --bg-container: white;
            --bg-panel: #e8f4f8;
            --bg-prereq-item: white;
            --bg-input: white;
            --bg-input-border: #e0e0e0;
            --text-primary: #333;
            --text-secondary: #555;
            --text-header: white;
            --border-primary: #3776ab;
            --btn-primary: linear-gradient(135deg, #3776ab 0%, #4a90c2 100%);
            --btn-primary-shadow: rgba(55, 118, 171, 0.4);
            --btn-secondary: #6c757d;
            --btn-secondary-hover: #5a6268;
            --alert-success-bg: #e1f0f7;
            --alert-success-text: #306998;
            --alert-success-border: #4a90c2;
            --alert-error-bg: #f8d7da;
            --alert-error-text: #721c24;
            --alert-error-border: #f5c6cb;
            --alert-info-bg: #d1ecf1;
            --alert-info-text: #0c5460;
            --alert-info-border: #bee5eb;
            --shadow-container: 0 20px 60px rgba(0,0,0,0.3);
        }
        
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: var(--bg-body);
            min-height: 100vh;
            padding: 20px;
            transition: background 0.3s ease;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: var(--bg-container);
            border-radius: 12px;
            box-shadow: var(--shadow-container);
            overflow: hidden;
            transition: background 0.3s ease, box-shadow 0.3s ease;
        }
        
        .header {
            background: var(--bg-header);
            color: var(--text-header);
            padding: 30px;
            text-align: center;
            transition: background 0.3s ease;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        
        .header p {
            opacity: 0.9;
            font-size: 1.1em;
        }
        
        .content {
            padding: 30px;
        }
        
        .section {
            margin-bottom: 30px;
        }
        
        .section h2 {
            color: var(--text-primary);
            margin-bottom: 15px;
            font-size: 1.5em;
            border-bottom: 2px solid var(--border-primary);
            padding-bottom: 10px;
            transition: color 0.3s ease, border-color 0.3s ease;
        }
        
        .form-group {
            margin-bottom: 20px;
        }
        
        .form-group label {
            display: block;
            margin-bottom: 5px;
            color: var(--text-secondary);
            font-weight: 500;
            transition: color 0.3s ease;
        }
        
        .form-row {
            display: flex;
            gap: 10px;
            align-items: flex-end;
        }
        
        .form-row input {
            flex: 1;
        }
        
        input[type="text"], input[type="number"] {
            width: 100%;
            padding: 12px;
            border: 2px solid var(--bg-input-border);
            border-radius: 6px;
            font-size: 14px;
            background: var(--bg-input);
            color: var(--text-primary);
            transition: border-color 0.3s ease, background 0.3s ease, color 0.3s ease;
        }
        
        input[type="text"]:focus, input[type="number"]:focus {
            outline: none;
            border-color: var(--border-primary);
        }
        
        .btn {
            padding: 12px 24px;
            border: none;
            border-radius: 6px;
            font-size: 14px;
            font-weight: 500;
            cursor: pointer;
            transition: all 0.3s;
            white-space: nowrap;
        }
        
        .btn-primary {
            background: var(--btn-primary);
            color: white;
        }
        
        .btn-primary:hover:not(:disabled) {
            transform: translateY(-2px);
            box-shadow: 0 5px 15px var(--btn-primary-shadow);
        }
        
        .btn-secondary {
            background: var(--btn-secondary);
            color: white;
        }
        
        .btn-secondary:hover:not(:disabled) {
            background: var(--btn-secondary-hover);
        }
        
        .btn:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }
        
        .prereq-panel {
            background: var(--bg-panel);
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            transition: background 0.3s ease;
        }
        
        .prereq-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px;
            margin-bottom: 10px;
            background: var(--bg-prereq-item);
            border-radius: 6px;
            border-left: 4px solid #ddd;
            transition: background 0.3s ease;
        }
        
        .prereq-item.ready {
            border-left-color: #28a745;
        }
        
        .prereq-item.not-ready {
            border-left-color: #dc3545;
        }
        
        .status-icon {
            font-size: 1.2em;
            margin-right: 10px;
        }
        
        .status-icon.ready::before {
            content: "\2713";
            color: #28a745;
        }
        
        .status-icon.not-ready::before {
            content: "\2717";
            color: #dc3545;
        }
        
        .progress-log {
            background: #1e1e1e;
            color: #d4d4d4;
            border-radius: 8px;
            padding: 20px;
            font-family: 'Consolas', 'Monaco', monospace;
            font-size: 13px;
            max-height: 400px;
            overflow-y: auto;
            margin-bottom: 20px;
        }
        
        .progress-log .log-entry {
            margin-bottom: 5px;
            padding: 4px 0;
        }
        
        .progress-log .log-entry.info {
            color: #4ec9b0;
        }
        
        .progress-log .log-entry.ok {
            color: #4ec9b0;
        }
        
        .progress-log .log-entry.error {
            color: #f48771;
        }
        
        .progress-log .log-entry.step {
            color: #dcdcaa;
            font-weight: bold;
        }
        
        .progress-log .log-entry.complete {
            color: #4ec9b0;
            font-weight: bold;
        }
        
        .alert {
            padding: 15px;
            border-radius: 6px;
            margin-bottom: 20px;
        }
        
        .alert-success {
            background: var(--alert-success-bg);
            color: var(--alert-success-text);
            border: 1px solid var(--alert-success-border);
            transition: background 0.3s ease, color 0.3s ease, border-color 0.3s ease;
        }
        
        .alert-error {
            background: var(--alert-error-bg);
            color: var(--alert-error-text);
            border: 1px solid var(--alert-error-border);
            transition: background 0.3s ease, color 0.3s ease, border-color 0.3s ease;
        }
        
        .alert-info {
            background: var(--alert-info-bg);
            color: var(--alert-info-text);
            border: 1px solid var(--alert-info-border);
            transition: background 0.3s ease, color 0.3s ease, border-color 0.3s ease;
        }
        
        .hidden {
            display: none;
        }
        
        .loading {
            display: inline-block;
            width: 16px;
            height: 16px;
            border: 3px solid rgba(255,255,255,.3);
            border-radius: 50%;
            border-top-color: #fff;
            animation: spin 1s ease-in-out infinite;
            margin-right: 8px;
        }
        
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Python Build Release</h1>
            <p>Build Python 3.10/3.11/3.12 Security Releases for Enterprise Deployment</p>
        </div>
        
        <div class="content">
            <div class="section">
                <h2>Prerequisites</h2>
                <div class="prereq-panel" id="prereqPanel">
                    <div style="text-align: center; padding: 20px;">
                        <div class="loading"></div>
                        <span>Checking prerequisites...</span>
                    </div>
                </div>
                <button class="btn btn-secondary" onclick="checkPrerequisites()">Refresh</button>
            </div>
            
            <div class="section">
                <h2>Build Configuration</h2>
                <div id="alertContainer"></div>
                
                <div class="form-group">
                    <label for="sourcePath">CPython Source Path</label>
                    <div class="form-row">
                        <input type="text" id="sourcePath" placeholder="C:\src\Python-3.11.14" />
                        <input type="file" id="sourcePathPicker" webkitdirectory directory style="display: none;" />
                        <button class="btn btn-secondary" type="button" onclick="browseFolder('sourcePath', 'sourcePathPicker')">Browse</button>
                        <button class="btn btn-secondary" onclick="validateSource()">Validate</button>
                    </div>
                </div>
                
                <div class="form-group">
                    <label for="bootstrapPython">Bootstrap Python (3.10 or 3.12)</label>
                    <div class="form-row">
                        <input type="text" id="bootstrapPython" placeholder="C:\...\python.exe" />
                        <input type="file" id="bootstrapPythonPicker" accept=".exe" style="display: none;" />
                        <button class="btn btn-secondary" type="button" onclick="browseFile('bootstrapPython', 'bootstrapPythonPicker')">Browse</button>
                        <button class="btn btn-secondary" onclick="detectPaths()">Auto-Detect</button>
                    </div>
                </div>
                
                <div class="form-group">
                    <label for="venvName">Virtual Environment Name</label>
                    <input type="text" id="venvName" value="doc-venv" />
                </div>
                
                <div class="form-group">
                    <label for="releaseRoot">Release Output Directory</label>
                    <div class="form-row">
                        <input type="text" id="releaseRoot" value="C:\python-releases" />
                        <input type="file" id="releaseRootPicker" webkitdirectory directory style="display: none;" />
                        <button class="btn btn-secondary" type="button" onclick="browseFolder('releaseRoot', 'releaseRootPicker')">Browse</button>
                    </div>
                </div>
                
                <div class="form-group">
                    <label for="winSdkVersion">Windows SDK Version</label>
                    <input type="text" id="winSdkVersion" value="10.0.19041.0" />
                </div>
                
                <div class="form-group">
                    <button class="btn btn-secondary" onclick="setupVenv()" id="setupVenvBtn">Setup Virtual Environment</button>
                </div>
            </div>
            
            <div class="section">
                <h2>Build Progress</h2>
                <div class="progress-log" id="progressLog">
                    <div class="log-entry info">Ready to build. Configure settings above and click 'Start Build'.</div>
                </div>
                <div style="display: flex; gap: 10px;">
                    <button class="btn btn-primary" onclick="startBuild()" id="startBuildBtn">Start Build</button>
                    <button class="btn btn-secondary" onclick="clearLog()" id="clearLogBtn">Clear Log</button>
                </div>
            </div>
        </div>
    </div>
    
    <script>
        let eventSource = null;
        let lastEventIndex = 0;
        
        function browseFolder(textInputId, fileInputId) {
            const textInput = document.getElementById(textInputId);
            
            if (!textInput) {
                showAlert('Text input not found. Please refresh the page.', 'error');
                return;
            }
            
            // Try File System Access API first (modern browsers, gives actual path)
            if (window.showDirectoryPicker) {
                window.showDirectoryPicker().then(function(directoryHandle) {
                    // File System Access API gives us the directory handle
                    // We can get the name, but not the full path due to browser security
                    // However, we can use the directory name
                    directoryHandle.getName().then(function(name) {
                        // Try to construct path from current input if it exists
                        const currentValue = textInput.value;
                        let folderPath = '';
                        
                        if (currentValue && currentValue.length > 0) {
                            // If there's already a path, try to use its parent and append the folder name
                            const parentMatch = currentValue.match(/^(.+)[\\/][^\\/]+$/);
                            if (parentMatch) {
                                folderPath = parentMatch[1] + '\\' + name;
                            } else {
                                folderPath = name;
                            }
                        } else {
                            folderPath = name;
                        }
                        
                        textInput.value = folderPath;
                        showAlert('Folder selected: ' + name + '. Please verify the full path is correct: ' + folderPath, 'info');
                        textInput.focus();
                        textInput.select();
                    }).catch(function(err) {
                        console.error('Error getting directory name:', err);
                        showAlert('Please enter the full folder path manually.', 'info');
                        textInput.focus();
                    });
                }).catch(function(err) {
                    // User cancelled or API not supported, fall back to webkitdirectory
                    if (err.name !== 'AbortError') {
                        console.log('File System Access API not available, using fallback:', err);
                    }
                    browseFolderFallback(textInputId, fileInputId);
                });
            } else {
                // Fallback to webkitdirectory for older browsers
                browseFolderFallback(textInputId, fileInputId);
            }
        }
        
        function browseFolderFallback(textInputId, fileInputId) {
            const textInput = document.getElementById(textInputId);
            
            // Create a new file input for folder selection
            const newFileInput = document.createElement('input');
            newFileInput.type = 'file';
            newFileInput.setAttribute('webkitdirectory', '');
            newFileInput.setAttribute('directory', '');
            newFileInput.style.display = 'none';
            document.body.appendChild(newFileInput);
            
            newFileInput.addEventListener('change', function() {
                try {
                    if (this.files && this.files.length > 0) {
                        const firstFile = this.files[0];
                        let folderPath = '';
                        
                        // Try to extract folder path from file path
                        const inputValue = this.value;
                        if (inputValue) {
                            // Remove fakepath prefix
                            let path = inputValue.replace(/^C:\\fakepath\\/i, '');
                            
                            // Remove filename to get folder
                            const lastBackslash = path.lastIndexOf('\\');
                            const lastSlash = path.lastIndexOf('/');
                            const lastSep = Math.max(lastBackslash, lastSlash);
                            
                            if (lastSep > 0) {
                                path = path.substring(0, lastSep);
                                path = path.replace(/\//g, '\\');
                                path = path.replace(/\\$/, '');
                                
                                if (path && path.length > 0 && path !== 'C:\\fakepath' && !path.startsWith('fakepath')) {
                                    folderPath = path;
                                }
                            }
                        }
                        
                        // If no path extracted, use folder name from webkitRelativePath
                        if (!folderPath && firstFile.webkitRelativePath) {
                            const parts = firstFile.webkitRelativePath.split(/[\\/]/);
                            if (parts.length > 0) {
                                folderPath = parts[0];
                            }
                        }
                        
                        if (folderPath && folderPath.length > 0) {
                            textInput.value = folderPath;
                            
                            // Check if it looks like a full path
                            if (folderPath.match(/^[A-Za-z]:\\/)) {
                                showAlert('Folder path set: ' + folderPath, 'success');
                            } else {
                                showAlert('Folder name: "' + folderPath + '". Browser security prevents full path access. Please enter the complete path manually (e.g., C:\\temp\\PythonEnv\\python_3.10\\Python-3.10.18\\Python-3.10.18)', 'info');
                                textInput.focus();
                                textInput.select();
                            }
                        } else {
                            showAlert('Browser security prevents accessing the full folder path. Please enter it manually (e.g., C:\\temp\\PythonEnv\\python_3.10\\Python-3.10.18\\Python-3.10.18)', 'info');
                            textInput.focus();
                        }
                    } else {
                        showAlert('No folder selected.', 'info');
                    }
                } catch (error) {
                    showAlert('Error selecting folder: ' + error.message, 'error');
                    console.error('Folder selection error:', error);
                } finally {
                    if (document.body.contains(newFileInput)) {
                        document.body.removeChild(newFileInput);
                    }
                }
            });
            
            newFileInput.click();
        }
        
        function browseFile(textInputId, fileInputId) {
            const fileInput = document.getElementById(fileInputId);
            const textInput = document.getElementById(textInputId);
            
            if (!fileInput) {
                showAlert('File input not found. Please refresh the page.', 'error');
                return;
            }
            
            // Create a new file input to avoid event listener issues
            const newFileInput = document.createElement('input');
            newFileInput.type = 'file';
            newFileInput.accept = '.exe';
            newFileInput.style.display = 'none';
            document.body.appendChild(newFileInput);
            
            newFileInput.addEventListener('change', function() {
                try {
                    if (this.files && this.files.length > 0) {
                        const inputValue = this.value;
                        if (inputValue) {
                            // Remove the fakepath prefix
                            let cleanPath = inputValue.replace(/^C:\\fakepath\\/i, '');
                            // Convert forward slashes to backslashes for Windows
                            cleanPath = cleanPath.replace(/\//g, '\\');
                            
                            if (cleanPath && cleanPath !== 'C:\\fakepath' && cleanPath.length > 0) {
                                textInput.value = cleanPath;
                                showAlert('File selected: ' + cleanPath, 'success');
                            } else {
                                // Browser is hiding the path - show filename
                                textInput.value = this.files[0].name;
                                showAlert('Browser security: Full path not available. Selected file: "' + this.files[0].name + '". Please enter the full path manually.', 'info');
                                textInput.focus();
                                textInput.select();
                            }
                        } else {
                            showAlert('Could not get file path. Please enter the full path manually.', 'info');
                            textInput.focus();
                        }
                    } else {
                        showAlert('No file selected.', 'info');
                    }
                } catch (error) {
                    showAlert('Error selecting file: ' + error.message, 'error');
                    console.error('File selection error:', error);
                } finally {
                    // Clean up
                    document.body.removeChild(newFileInput);
                }
            });
            
            // Trigger file picker
            newFileInput.click();
        }
        
        function showAlert(message, type = 'info') {
            const container = document.getElementById('alertContainer');
            const alert = document.createElement('div');
            alert.className = 'alert alert-' + type;
            alert.textContent = message;
            container.appendChild(alert);
            setTimeout(() => alert.remove(), 5000);
        }
        
        function addLogEntry(message, type = 'info') {
            const log = document.getElementById('progressLog');
            const entry = document.createElement('div');
            entry.className = 'log-entry ' + type;
            entry.textContent = '[' + new Date().toLocaleTimeString() + '] ' + message;
            log.appendChild(entry);
            log.scrollTop = log.scrollHeight;
        }
        
        function clearLog() {
            document.getElementById('progressLog').innerHTML = '';
            lastEventIndex = 0;
        }
        
        async function checkPrerequisites() {
            const panel = document.getElementById('prereqPanel');
            panel.innerHTML = '<div style="text-align: center; padding: 20px;"><div class="loading"></div><span>Checking prerequisites...</span></div>';
            
            try {
                const response = await fetch('/api/prerequisites');
                const data = await response.json();
                
                let html = '';
                
                const vsStatus = data.VisualStudio.Installed ? 'ready' : 'not-ready';
                const vsIcon = data.VisualStudio.Installed ? 'ready' : 'not-ready';
                const vsPath = data.VisualStudio.Installed ? (data.VisualStudio.Path || 'Installed') : 'Not Found';
                html += '<div class="prereq-item ' + vsStatus + '">' +
                    '<div><span class="status-icon ' + vsIcon + '"></span><strong>Visual Studio 2019</strong></div>' +
                    '<div>' + vsPath + '</div>' +
                    '</div>';
                
                const toolchainStatus = data.MSVCToolchains.AllPresent ? 'ready' : 'not-ready';
                const toolchainIcon = data.MSVCToolchains.AllPresent ? 'ready' : 'not-ready';
                const toolchainMsg = data.MSVCToolchains.AllPresent 
                    ? 'All toolchains present' 
                    : ('Missing: ' + data.MSVCToolchains.Missing.join(', '));
                html += '<div class="prereq-item ' + toolchainStatus + '">' +
                    '<div><span class="status-icon ' + toolchainIcon + '"></span><strong>MSVC Toolchains (v142)</strong></div>' +
                    '<div>' + toolchainMsg + '</div>' +
                    '</div>';
                
                const sdkStatus = data.WindowsSDK.Installed ? 'ready' : 'not-ready';
                const sdkIcon = data.WindowsSDK.Installed ? 'ready' : 'not-ready';
                const sdkMsg = data.WindowsSDK.Installed ? 
                    ('Version ' + data.WindowsSDK.Version) : 
                    ('Required: ' + data.WindowsSDK.RequiredVersion);
                html += '<div class="prereq-item ' + sdkStatus + '">' +
                    '<div><span class="status-icon ' + sdkIcon + '"></span><strong>Windows SDK</strong></div>' +
                    '<div>' + sdkMsg + '</div>' +
                    '</div>';
                
                const pythonStatus = data.BootstrapPython.Found ? 'ready' : 'not-ready';
                const pythonIcon = data.BootstrapPython.Found ? 'ready' : 'not-ready';
                const pythonMsg = data.BootstrapPython.Found ? 
                    (data.BootstrapPython.Versions.length + ' version(s) found') : 
                    'Not Found';
                html += '<div class="prereq-item ' + pythonStatus + '">' +
                    '<div><span class="status-icon ' + pythonIcon + '"></span><strong>Bootstrap Python (3.10/3.12)</strong></div>' +
                    '<div>' + pythonMsg + '</div>' +
                    '</div>';
                
                if (data.AllReady) {
                    html += '<div class="alert alert-success" style="margin-top: 15px;">All prerequisites are ready!</div>';
                } else {
                    html += '<div class="alert alert-error" style="margin-top: 15px;">Some prerequisites are missing. Please install them before building.</div>';
                }
                
                panel.innerHTML = html;
            } catch (error) {
                panel.innerHTML = '<div class="alert alert-error">Error checking prerequisites: ' + error.message + '</div>';
            }
        }
        
        async function detectPaths() {
            try {
                const response = await fetch('/api/detect-paths');
                const data = await response.json();
                
                if (data.Python) {
                    document.getElementById('bootstrapPython').value = data.Python;
                    showAlert('Python path auto-detected', 'success');
                } else {
                    showAlert('No compatible Python found. Please install Python 3.10 or 3.12.', 'error');
                }
            } catch (error) {
                showAlert('Error detecting paths: ' + error.message, 'error');
            }
        }
        
        async function validateSource() {
            const sourcePath = document.getElementById('sourcePath').value;
            if (!sourcePath) {
                showAlert('Please enter a source path', 'error');
                return;
            }
            
            try {
                const response = await fetch('/api/validate-source', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ SourcePath: sourcePath })
                });
                const data = await response.json();
                
                if (data.Valid) {
                    showAlert('Source path is valid', 'success');
                } else {
                    showAlert('Invalid source path: ' + data.Errors.join(', '), 'error');
                }
            } catch (error) {
                showAlert('Error validating source: ' + error.message, 'error');
            }
        }
        
        async function setupVenv() {
            const sourcePath = document.getElementById('sourcePath').value;
            const bootstrapPython = document.getElementById('bootstrapPython').value;
            const venvName = document.getElementById('venvName').value;
            
            if (!sourcePath || !bootstrapPython) {
                showAlert('Please provide source path and bootstrap Python', 'error');
                return;
            }
            
            const btn = document.getElementById('setupVenvBtn');
            btn.disabled = true;
            btn.textContent = 'Setting up...';
            
            try {
                const response = await fetch('/api/setup-venv', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        SourcePath: sourcePath,
                        BootstrapPython: bootstrapPython,
                        VenvName: venvName
                    })
                });
                const data = await response.json();
                
                if (data.Success) {
                    const message = data.Message || 'Virtual environment ready';
                    showAlert(message, 'success');
                    
                    // Update button to show venv is created/updated
                    const statusText = data.Message && data.Message.includes('updated') 
                        ? '✓ Virtual Environment Updated: ' 
                        : '✓ Virtual Environment Created: ';
                    btn.textContent = statusText + venvName;
                    btn.style.background = 'var(--alert-success-bg)';
                    btn.style.color = 'var(--alert-success-text)';
                    btn.style.border = '1px solid var(--alert-success-border)';
                    btn.style.cursor = 'default';
                    btn.disabled = false;
                } else {
                    showAlert('Failed to create venv: ' + data.Error, 'error');
                    btn.disabled = false;
                    btn.textContent = 'Setup Virtual Environment';
                    // Reset button styles on error
                    btn.style.background = '';
                    btn.style.color = '';
                    btn.style.border = '';
                    btn.style.cursor = '';
                }
            } catch (error) {
                showAlert('Error setting up venv: ' + error.message, 'error');
                btn.disabled = false;
                btn.textContent = 'Setup Virtual Environment';
            }
        }
        
        function startBuild() {
            const sourcePath = document.getElementById('sourcePath').value;
            const bootstrapPython = document.getElementById('bootstrapPython').value;
            const venvName = document.getElementById('venvName').value;
            const releaseRoot = document.getElementById('releaseRoot').value;
            const winSdkVersion = document.getElementById('winSdkVersion').value;
            
            if (!sourcePath || !bootstrapPython) {
                showAlert('Please provide source path and bootstrap Python', 'error');
                return;
            }
            
            const startBtn = document.getElementById('startBuildBtn');
            startBtn.disabled = true;
            startBtn.textContent = 'Starting...';
            
            clearLog();
            addLogEntry('Starting build process...', 'info');
            
            fetch('/api/build', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    SourcePath: sourcePath,
                    BootstrapPython: bootstrapPython,
                    VenvName: venvName,
                    ReleaseRoot: releaseRoot,
                    WinSdkVersion: winSdkVersion
                })
            })
            .then(response => response.json())
            .then(data => {
                if (data.Success) {
                    startProgressStream();
                    startBtn.textContent = 'Build Running...';
                } else {
                    showAlert('Failed to start build: ' + data.Error, 'error');
                    startBtn.disabled = false;
                    startBtn.textContent = 'Start Build';
                }
            })
            .catch(error => {
                showAlert('Error starting build: ' + error.message, 'error');
                startBtn.disabled = false;
                startBtn.textContent = 'Start Build';
            });
        }
        
        function startProgressStream() {
            if (eventSource) {
                eventSource.close();
            }
            
            eventSource = new EventSource('/api/progress?since=' + lastEventIndex);
            
            eventSource.onmessage = function(event) {
                if (event.data.startsWith('{')) {
                    const data = JSON.parse(event.data);
                    
                    if (data.Type === 'complete') {
                        addLogEntry(data.Message, data.Success ? 'complete' : 'error');
                        eventSource.close();
                        eventSource = null;
                        
                        const startBtn = document.getElementById('startBuildBtn');
                        startBtn.disabled = false;
                        startBtn.textContent = 'Start Build';
                        
                        if (data.Success) {
                            showAlert('Build completed successfully!', 'success');
                        } else {
                            showAlert('Build failed. Check the log for details.', 'error');
                        }
                    } else {
                        addLogEntry(data.Message, data.Type);
                        lastEventIndex++;
                    }
                }
            };
            
            eventSource.onerror = function(error) {
                console.error('SSE error:', error);
                if (eventSource.readyState === EventSource.CLOSED) {
                    eventSource = null;
                    const startBtn = document.getElementById('startBuildBtn');
                    startBtn.disabled = false;
                    startBtn.textContent = 'Start Build';
                }
            };
        }
        
        // Initialize
        checkPrerequisites();
        detectPaths();
    </script>
</body>
</html>
"@
}

# --- Main Server Loop --------------------------------------------------------

function Start-WebServer {
    $listener = New-Object System.Net.HttpListener
    $url = "http://localhost:$Port/"
    $listener.Prefixes.Add($url)
    
    # Store listener in script scope for cleanup
    $script:ServerListener = $listener
    
    try {
        $listener.Start()
        Write-Ok "Web server started at $url"
        Write-Info "Press Ctrl+C to stop the server"
        
        # Try to open browser
        try {
            Start-Process $url
        } catch {
            Write-Info "Could not open browser automatically. Please navigate to $url"
        }
        
        # Use async context handling to allow interrupt
        $asyncResult = $null
        
        while ($listener.IsListening) {
            try {
                # Use BeginGetContext for non-blocking operation
                if ($null -eq $asyncResult) {
                    $asyncResult = $listener.BeginGetContext($null, $null)
                }
                
                # Wait for context with timeout to allow interrupt checking
                $waitHandle = $asyncResult.AsyncWaitHandle
                if ($waitHandle.WaitOne(1000)) {
                    $context = $listener.EndGetContext($asyncResult)
                    $asyncResult = $null
                    
                    $request = $context.Request
                    $path = $request.Url.AbsolutePath
                    
                    try {
                        if ($path -eq "/" -or $path -eq "") {
                            Invoke-RootHandler -Context $context
                        } elseif ($path -eq "/api/prerequisites") {
                            Invoke-PrerequisitesHandler -Context $context
                        } elseif ($path -eq "/api/detect-paths") {
                            Invoke-DetectPathsHandler -Context $context
                        } elseif ($path -eq "/api/validate-source") {
                            Invoke-ValidateSourceHandler -Context $context
                        } elseif ($path -eq "/api/setup-venv") {
                            Invoke-SetupVenvHandler -Context $context
                        } elseif ($path -eq "/api/build") {
                            Invoke-BuildHandler -Context $context
                        } elseif ($path -eq "/api/progress") {
                            Invoke-ProgressHandler -Context $context
                        } else {
                            Send-TextResponse -Context $context -Text "Not Found" -StatusCode 404
                        }
                    } catch {
                        Write-Err "Error handling request: $($_.Exception.Message)"
                        try {
                            Send-TextResponse -Context $context -Text "Internal Server Error: $($_.Exception.Message)" -StatusCode 500
                        } catch {
                            # Client may have disconnected
                        }
                    }
                }
            } catch [System.Net.HttpListenerException] {
                # Listener was stopped
                break
            } catch [System.Management.Automation.PipelineStoppedException] {
                # Ctrl+C was pressed
                Write-Host ""
                Write-Info "Shutting down server..."
                break
            } catch {
                if ($listener.IsListening) {
                    Write-Err "Error in server loop: $($_.Exception.Message)"
                }
                Start-Sleep -Milliseconds 100
            }
        }
    } catch [System.Net.HttpListenerException] {
        if ($_.Exception.Message -notmatch "The I/O operation has been aborted") {
            Write-Err "Failed to start web server: $($_.Exception.Message)"
            Write-Info "Make sure you have administrator privileges or the port is not in use"
            exit 1
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host ""
        Write-Info "Shutting down server..."
    } catch {
        Write-Err "Failed to start web server: $($_.Exception.Message)"
        Write-Info "Make sure you have administrator privileges or the port is not in use"
        exit 1
    } finally {
        $script:ServerListener = $null
        if ($listener.IsListening) {
            $listener.Stop()
        }
        if ($script:BuildJob -and -not $script:BuildJob.HasExited) {
            try {
                $script:BuildJob.Kill()
            } catch {
                # Process already exited
            }
        }
        Write-Ok "Server stopped."
    }
}

# --- Entry Point -------------------------------------------------------------

Write-Info "Python Build Release Web UI"
Write-Info "============================"
Write-Info "Build Script: $BuildScriptPath"

if (-not (Test-Path $BuildScriptPath)) {
    Write-Err "Build script not found: $BuildScriptPath"
    exit 1
}

# Set up trap for Ctrl+C
trap {
    if ($_.Exception -is [System.OperationCanceledException] -or 
        $_.Exception.Message -match "canceled|aborted|interrupt") {
        Write-Host ""
        Write-Info "Shutting down server..."
        if ($script:ServerListener -and $script:ServerListener.IsListening) {
            $script:ServerListener.Stop()
        }
        if ($script:BuildJob -and -not $script:BuildJob.HasExited) {
            try {
                $script:BuildJob.Kill()
            } catch {
                # Process already exited
            }
        }
        break
    }
    throw
}

# Register cleanup on exit
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    if ($script:ServerListener -and $script:ServerListener.IsListening) {
        $script:ServerListener.Stop()
    }
    if ($script:BuildJob) {
        Stop-Job -Job $script:BuildJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:BuildJob -ErrorAction SilentlyContinue
    }
} | Out-Null

Start-WebServer


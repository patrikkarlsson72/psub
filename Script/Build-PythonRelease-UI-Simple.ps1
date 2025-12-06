#requires -Version 5.1

<#
.SYNOPSIS
    Simple web UI for Python builds - opens build in new window
#>

param(
    [int]$Port = 8080,
    [string]$BuildScriptPath = (Join-Path $PSScriptRoot "Build-PythonRelease.ps1")
)

$ErrorActionPreference = "Stop"

# Global state
$script:ServerListener = $null
$script:BuildStatus = @{}  # Track build status by ID

function Write-Info($msg) {
    Write-Host "[INFO] $msg" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}

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
        [string]$ContentType = "text/html",
        [int]$StatusCode = 200
    )
    
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Text)
    
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = "$ContentType; charset=utf-8"
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

function Find-VcVars64 {
    $vsPaths = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise"
    )
    
    foreach ($vsPath in $vsPaths) {
        $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $vcvars) {
            return $vcvars
        }
    }
    
    return $null
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
        try {
            $dirs = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue -Directory
            foreach ($dir in $dirs) {
                $pythonExe = Join-Path $dir.FullName "python.exe"
                if (Test-Path $pythonExe) {
                    try {
                        $versionOutput = & $pythonExe --version 2>&1
                        $versionStr = $versionOutput | Out-String
                        
                        if ($versionStr -match 'Python\s+(\d+)\.(\d+)') {
                            $major = [int]$matches[1]
                            $minor = [int]$matches[2]
                            
                            # Accept Python 3.10 or 3.12 only
                            if (($major -eq 3) -and (($minor -eq 10) -or ($minor -eq 12))) {
                                $found += @{
                                    Path = $pythonExe
                                    Version = "Python $major.$minor"
                                    Major = $major
                                    Minor = $minor
                                }
                            }
                        }
                    } catch {
                        # Skip this python.exe if version check fails
                    }
                }
            }
        } catch {
            # Skip this search path if it fails
        }
    }
    
    # Sort by version (prefer 3.12 over 3.10)
    return $found | Sort-Object { $_.Minor } -Descending
}

function Invoke-SetupVenvHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    $body = Get-RequestBody -Context $Context
    $data = $body | ConvertFrom-Json
    
    # Validate
    if ([string]::IsNullOrWhiteSpace($data.SourcePath)) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "SourcePath is required" } -StatusCode 400
        return
    }
    
    if ([string]::IsNullOrWhiteSpace($data.BootstrapPython)) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "BootstrapPython is required" } -StatusCode 400
        return
    }
    
    $venvName = if ($data.VenvName) { $data.VenvName } else { "doc-venv" }
    $venvPath = Join-Path $data.SourcePath $venvName
    $requirementsPath = Join-Path $data.SourcePath "Doc\requirements.txt"
    $pipPath = Join-Path $venvPath "Scripts\pip.exe"
    
    # Check if requirements.txt exists
    if (-not (Test-Path $requirementsPath)) {
        Send-JsonResponse -Context $Context -Data @{ 
            Success = $false
            Error = "Doc\requirements.txt not found at: $requirementsPath"
        } -StatusCode 400
        return
    }
    
    try {
        # Check if venv already exists
        if (Test-Path $venvPath) {
            # Venv exists - just install/update requirements
            if (-not (Test-Path $pipPath)) {
                Send-JsonResponse -Context $Context -Data @{ 
                    Success = $false
                    Error = "Venv exists but pip.exe not found. Venv may be corrupted."
                } -StatusCode 400
                return
            }
            
            Write-Info "Updating venv: $venvPath"
            $proc = Start-Process -FilePath $pipPath `
                -ArgumentList @("install", "-r", $requirementsPath, "--upgrade") `
                -NoNewWindow -Wait -PassThru
            
            if ($proc.ExitCode -ne 0) {
                Send-JsonResponse -Context $Context -Data @{ 
                    Success = $false
                    Error = "Failed to install requirements (exit code: $($proc.ExitCode))"
                } -StatusCode 500
                return
            }
            
            Send-JsonResponse -Context $Context -Data @{ 
                Success = $true
                Message = "Requirements updated in existing venv"
                VenvPath = $venvPath
            }
        } else {
            # Create new venv
            Write-Info "Creating new venv: $venvPath"
            $proc = Start-Process -FilePath $data.BootstrapPython `
                -ArgumentList @("-m", "venv", $venvPath) `
                -NoNewWindow -Wait -PassThru
            
            if ($proc.ExitCode -ne 0) {
                Send-JsonResponse -Context $Context -Data @{ 
                    Success = $false
                    Error = "Failed to create venv (exit code: $($proc.ExitCode))"
                } -StatusCode 500
                return
            }
            
            # Install requirements
            if (-not (Test-Path $pipPath)) {
                Send-JsonResponse -Context $Context -Data @{ 
                    Success = $false
                    Error = "pip.exe not found after venv creation"
                } -StatusCode 500
                return
            }
            
            Write-Info "Installing requirements..."
            $proc = Start-Process -FilePath $pipPath `
                -ArgumentList @("install", "-r", $requirementsPath) `
                -NoNewWindow -Wait -PassThru
            
            if ($proc.ExitCode -ne 0) {
                Send-JsonResponse -Context $Context -Data @{ 
                    Success = $false
                    Error = "Failed to install requirements (exit code: $($proc.ExitCode))"
                } -StatusCode 500
                return
            }
            
            Send-JsonResponse -Context $Context -Data @{ 
                Success = $true
                Message = "Virtual environment created successfully"
                VenvPath = $venvPath
            }
        }
    } catch {
        Send-JsonResponse -Context $Context -Data @{ 
            Success = $false
            Error = $_.Exception.Message
        } -StatusCode 500
    }
}

function Invoke-BuildHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    $body = Get-RequestBody -Context $Context
    $data = $body | ConvertFrom-Json
    
    # Validate
    if ([string]::IsNullOrWhiteSpace($data.SourcePath)) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "SourcePath is required" } -StatusCode 400
        return
    }
    
    if ([string]::IsNullOrWhiteSpace($data.BootstrapPython)) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "BootstrapPython is required" } -StatusCode 400
        return
    }
    
    # Find vcvars64.bat
    $vcvarsPath = Find-VcVars64
    if (-not $vcvarsPath) {
        Send-JsonResponse -Context $Context -Data @{ Success = $false; Error = "Visual Studio 2019 not found" } -StatusCode 400
        return
    }
    
    # Create a simple batch file that opens a new window and runs the build
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $buildId = [guid]::NewGuid().ToString()
    $batchFile = Join-Path $env:TEMP "python-build-$timestamp.bat"
    $statusFile = Join-Path $env:TEMP "python-build-status-$buildId.txt"
    
    # Store build status
    $script:BuildStatus[$buildId] = @{
        Status = "running"
        StartTime = Get-Date
        StatusFile = $statusFile
    }
    
    $batchContent = @"
@echo off
title Python Build - %TIME%
color 0A
echo ========================================
echo Python Build Started
echo ========================================
echo.
echo Setting up Visual Studio environment...
call "$vcvarsPath"
if errorlevel 1 (
    echo.
    echo ERROR: Failed to set up Visual Studio environment
    echo failed > "$statusFile"
    pause
    exit /b 1
)
echo.
echo Visual Studio environment ready
echo.
echo Starting build...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$BuildScriptPath' -SourcePath '$($data.SourcePath)' -BootstrapPython '$($data.BootstrapPython)' -VenvName '$($data.VenvName)' -ReleaseRoot '$($data.ReleaseRoot)' -WinSdkVersion '$($data.WinSdkVersion)'"
echo.
if errorlevel 1 (
    echo ========================================
    echo BUILD FAILED
    echo ========================================
    echo failed > "$statusFile"
) else (
    echo ========================================
    echo BUILD SUCCEEDED
    echo ========================================
    echo success > "$statusFile"
)
echo.
echo Press any key to close this window...
pause >nul
"@
    
    Set-Content -Path $batchFile -Value $batchContent -Encoding ASCII
    
    # Start the build in a new window
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$batchFile`"")
    
    Send-JsonResponse -Context $Context -Data @{ 
        Success = $true
        Message = "Build started in new window"
        BuildId = $buildId
    }
}

function Invoke-BuildStatusHandler {
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$BuildId
    )
    
    if (-not $script:BuildStatus.ContainsKey($BuildId)) {
        Send-JsonResponse -Context $Context -Data @{ 
            Status = "unknown"
            Message = "Build ID not found"
        } -StatusCode 404
        return
    }
    
    $buildInfo = $script:BuildStatus[$BuildId]
    $statusFile = $buildInfo.StatusFile
    
    if (Test-Path $statusFile) {
        $status = Get-Content $statusFile -Raw
        $status = $status.Trim()
        
        $script:BuildStatus[$BuildId].Status = $status
        
        Send-JsonResponse -Context $Context -Data @{
            Status = $status
            Message = if ($status -eq "success") { "Build completed successfully" } else { "Build failed" }
        }
    } else {
        Send-JsonResponse -Context $Context -Data @{
            Status = "running"
            Message = "Build is still running"
        }
    }
}

function Get-HtmlUI {
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PSUB - Python Security Update Builder</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: url('/assets/background.png') center center / cover no-repeat fixed, linear-gradient(135deg, rgba(30, 60, 100, 0.85) 0%, rgba(20, 40, 70, 0.85) 100%);
            min-height: 100vh;
            padding: 20px;
            position: relative;
        }
        body::before {
            content: '';
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: rgba(15, 25, 45, 0.4);
            z-index: 0;
            pointer-events: none;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: transparent;
            border-radius: 16px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.5);
            overflow: hidden;
            position: relative;
            z-index: 1;
        }
        .header {
            background: rgba(15, 25, 45, 0.8);
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            color: white;
            padding: 40px 30px;
            text-align: center;
            position: relative;
            overflow: hidden;
            border: 1px solid rgba(55, 118, 171, 0.5);
            border-bottom: 1px solid rgba(55, 118, 171, 0.3);
            box-shadow: 0 0 20px rgba(55, 118, 171, 0.2);
            border-radius: 16px 16px 0 0;
        }
        .header::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: linear-gradient(180deg, rgba(255, 255, 255, 0.05) 0%, rgba(255, 255, 255, 0) 100%);
            pointer-events: none;
        }
        .header h1 { 
            font-size: 2.8em; 
            margin-bottom: 10px; 
            text-shadow: 0 4px 20px rgba(0,0,0,0.5);
            position: relative;
            z-index: 1;
            font-weight: 700;
            letter-spacing: -0.5px;
            background: linear-gradient(to right, #ffffff, #e0e0e0);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .header p {
            position: relative;
            z-index: 1;
            opacity: 0.8;
            font-size: 0.9em;
            letter-spacing: 1px;
            text-transform: uppercase;
            color: #a0c0e0;
        }
        .content { 
            padding: 30px;
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            -webkit-backdrop-filter: blur(10px);
        }
        .section { margin-bottom: 30px; }
        .section h2 {
            color: #1a3c5e;
            margin-bottom: 25px;
            font-size: 1.4em;
            border-bottom: 2px solid transparent;
            border-image: linear-gradient(to right, #3776ab, rgba(55, 118, 171, 0)) 1;
            padding-bottom: 10px;
            font-weight: 600;
            display: flex;
            align-items: center;
        }
        .section h2::before {
            content: '';
            display: inline-block;
            width: 6px;
            height: 24px;
            background: #3776ab;
            margin-right: 12px;
            border-radius: 2px;
        }
        .form-group { margin-bottom: 24px; }
        .form-group label {
            display: block;
            margin-bottom: 8px;
            color: #4a5568;
            font-weight: 600;
            font-size: 0.9em;
            letter-spacing: 0.3px;
        }
        .form-row {
            display: flex;
            gap: 12px;
            align-items: flex-end;
        }
        .form-row input { flex: 1; }
        input[type="text"] {
            width: 100%;
            padding: 14px;
            border: 1px solid #cbd5e0;
            border-radius: 8px;
            font-size: 14px;
            background: #f8fafc;
            color: #2d3748;
            transition: all 0.3s ease;
            box-shadow: inset 0 2px 4px rgba(0,0,0,0.02);
        }
        input[type="text"]:focus {
            outline: none;
            border-color: #3776ab;
            background: white;
            box-shadow: 0 0 0 3px rgba(55, 118, 171, 0.15), inset 0 1px 2px rgba(0,0,0,0.05);
        }
        .btn {
            padding: 14px 28px;
            border: none;
            border-radius: 8px;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            letter-spacing: 0.3px;
        }
        .btn-primary {
            background: linear-gradient(135deg, #3776ab 0%, #2b5d88 100%);
            color: white;
            box-shadow: 0 4px 6px rgba(55, 118, 171, 0.2);
        }
        .btn-primary:hover:not(:disabled) {
            transform: translateY(-1px);
            box-shadow: 0 8px 15px rgba(55, 118, 171, 0.3);
        }
        .btn-secondary {
            background: transparent;
            color: #3776ab;
            border: 1px solid #b3cce6;
        }
        .btn-secondary:hover { 
            background: #f0f7fc;
            border-color: #3776ab;
            color: #2b5d88;
        }
        .btn:disabled {
            opacity: 0.6;
            cursor: not-allowed;
            transform: none;
        }
        .alert {
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 20px;
            backdrop-filter: blur(5px);
            -webkit-backdrop-filter: blur(5px);
            box-shadow: 0 2px 8px rgba(0,0,0,0.05);
        }
        .alert-success {
            background: rgba(212, 237, 218, 0.9);
            color: #155724;
            border: 1px solid rgba(195, 230, 203, 0.8);
        }
        .alert-error {
            background: rgba(248, 215, 218, 0.9);
            color: #721c24;
            border: 1px solid rgba(245, 198, 203, 0.8);
        }
        .alert-info {
            background: rgba(209, 236, 241, 0.9);
            color: #0c5460;
            border: 1px solid rgba(190, 229, 235, 0.8);
        }
        .hidden { display: none; }
        .note {
            background: rgba(235, 245, 255, 0.8);
            border-left: 4px solid #3776ab;
            border-radius: 4px;
            padding: 16px 20px;
            margin-bottom: 30px;
            color: #2c5282;
            font-size: 0.95em;
            line-height: 1.5;
        }
        .note strong { color: #1a3c5e; margin-bottom: 4px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>PSUB</h1>
            <p>Python Security Update Builder</p>
        </div>
        
        <div class="content">
            <div class="note">
                <strong>Note:</strong> The build will open in a new terminal window where you can see all output in real-time.
            </div>
            
            <div class="section">
                <h2>Build Configuration</h2>
                <div id="alertContainer"></div>
                
                <div class="form-group">
                    <label for="sourcePath">CPython Source Path</label>
                    <input type="text" id="sourcePath" placeholder="C:\src\Python-3.10.18\Python-3.10.18\Python-3.10.18" />
                </div>
                
                <div class="form-group">
                    <label for="bootstrapPython">Bootstrap Python (3.10 or 3.12)</label>
                    <div class="form-row">
                        <input type="text" id="bootstrapPython" placeholder="C:\...\python.exe" />
                        <button class="btn btn-secondary" onclick="detectPaths()">Auto-Detect</button>
                    </div>
                </div>
                
                <div class="form-group">
                    <label for="venvName">Virtual Environment Name</label>
                    <input type="text" id="venvName" value="doc-venv" />
                </div>
                
                <div class="form-group">
                    <label for="releaseRoot">Release Output Directory</label>
                    <input type="text" id="releaseRoot" value="C:\python-releases" />
                </div>
                
                <div class="form-group">
                    <label for="winSdkVersion">Windows SDK Version</label>
                    <input type="text" id="winSdkVersion" value="10.0.19041.0" />
                </div>
                
                <div class="form-group">
                    <button class="btn btn-secondary" onclick="setupVenv()" id="setupVenvBtn">Setup Virtual Environment</button>
                </div>
                
                <button class="btn btn-primary" onclick="startBuild()" id="startBuildBtn">Start Build (Opens New Window)</button>
            </div>
        </div>
    </div>
    
    <script>
        function showAlert(message, type = 'info') {
            const container = document.getElementById('alertContainer');
            const alert = document.createElement('div');
            alert.className = 'alert alert-' + type;
            alert.textContent = message;
            container.appendChild(alert);
            setTimeout(() => alert.remove(), 5000);
        }
        
        async function detectPaths() {
            try {
                const response = await fetch('/api/detect-paths');
                const data = await response.json();
                
                if (data.Python) {
                    document.getElementById('bootstrapPython').value = data.Python;
                    showAlert('Python path auto-detected', 'success');
                } else {
                    showAlert('No compatible Python found', 'error');
                }
            } catch (error) {
                showAlert('Error detecting paths: ' + error.message, 'error');
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
                    
                    // Update button to show success
                    const statusText = data.Message && data.Message.includes('updated') 
                        ? 'Venv Updated: ' 
                        : 'Venv Created: ';
                    btn.textContent = statusText + venvName;
                    btn.style.background = '#28a745';
                    btn.style.color = 'white';
                    btn.style.borderColor = '#28a745';
                    btn.style.cursor = 'default';
                } else {
                    showAlert('Failed to setup venv: ' + data.Error, 'error');
                    btn.disabled = false;
                    btn.textContent = 'Setup Virtual Environment';
                    btn.style.background = '';
                    btn.style.cursor = '';
                }
            } catch (error) {
                showAlert('Error setting up venv: ' + error.message, 'error');
                btn.disabled = false;
                btn.textContent = 'Setup Virtual Environment';
            }
        }
        
        let currentBuildId = null;
        let buildStatusInterval = null;
        
        async function checkBuildStatus(buildId) {
            try {
                const response = await fetch('/api/build-status/' + buildId);
                const data = await response.json();
                
                const btn = document.getElementById('startBuildBtn');
                
                if (data.Status === 'running') {
                    btn.textContent = 'Building...';
                    btn.style.background = 'linear-gradient(135deg, #f59e0b 0%, #d97706 100%)';
                } else if (data.Status === 'success') {
                    btn.textContent = 'Build Finished Successfully!';
                    btn.style.background = 'linear-gradient(135deg, #10b981 0%, #059669 100%)';
                    btn.disabled = false;
                    showAlert('Build completed successfully!', 'success');
                    clearInterval(buildStatusInterval);
                    buildStatusInterval = null;
                    currentBuildId = null;
                    
                    // Reset button after 5 seconds
                    setTimeout(() => {
                        btn.textContent = 'Start Build (Opens New Window)';
                        btn.style.background = '';
                    }, 5000);
                } else if (data.Status === 'failed') {
                    btn.textContent = 'Build Failed';
                    btn.style.background = 'linear-gradient(135deg, #ef4444 0%, #dc2626 100%)';
                    btn.disabled = false;
                    showAlert('Build failed. Check terminal window for details.', 'error');
                    clearInterval(buildStatusInterval);
                    buildStatusInterval = null;
                    currentBuildId = null;
                    
                    // Reset button after 5 seconds
                    setTimeout(() => {
                        btn.textContent = 'Start Build (Opens New Window)';
                        btn.style.background = '';
                    }, 5000);
                }
            } catch (error) {
                console.error('Error checking build status:', error);
            }
        }
        
        async function startBuild() {
            const sourcePath = document.getElementById('sourcePath').value;
            const bootstrapPython = document.getElementById('bootstrapPython').value;
            const venvName = document.getElementById('venvName').value;
            const releaseRoot = document.getElementById('releaseRoot').value;
            const winSdkVersion = document.getElementById('winSdkVersion').value;
            
            if (!sourcePath || !bootstrapPython) {
                showAlert('Please provide source path and bootstrap Python', 'error');
                return;
            }
            
            const btn = document.getElementById('startBuildBtn');
            btn.disabled = true;
            btn.textContent = 'Starting...';
            
            try {
                const response = await fetch('/api/build', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        SourcePath: sourcePath,
                        BootstrapPython: bootstrapPython,
                        VenvName: venvName,
                        ReleaseRoot: releaseRoot,
                        WinSdkVersion: winSdkVersion
                    })
                });
                const data = await response.json();
                
                if (data.Success) {
                    showAlert('Build started! Check the new terminal window for progress.', 'success');
                    currentBuildId = data.BuildId;
                    btn.textContent = 'Building...';
                    btn.style.background = 'linear-gradient(135deg, #f59e0b 0%, #d97706 100%)';
                    
                    // Poll build status every 2 seconds
                    if (buildStatusInterval) {
                        clearInterval(buildStatusInterval);
                    }
                    buildStatusInterval = setInterval(() => checkBuildStatus(currentBuildId), 2000);
                } else {
                    showAlert('Failed to start build: ' + data.Error, 'error');
                    btn.disabled = false;
                    btn.textContent = 'Start Build (Opens New Window)';
                    btn.style.background = '';
                }
            } catch (error) {
                showAlert('Error starting build: ' + error.message, 'error');
                btn.disabled = false;
                btn.textContent = 'Start Build (Opens New Window)';
                btn.style.background = '';
            }
        }
        
        // Auto-detect on load
        detectPaths();
    </script>
</body>
</html>
"@
}

function Start-WebServer {
    $listener = New-Object System.Net.HttpListener
    $url = "http://localhost:$Port/"
    $listener.Prefixes.Add($url)
    
    $script:ServerListener = $listener
    
    try {
        $listener.Start()
        Write-Ok "Web server started at $url"
        Write-Info "Press Ctrl+C to stop"
        
        try {
            Start-Process $url
        } catch {
            Write-Info "Navigate to $url"
        }
        
        # Use async context handling to allow Ctrl+C
        $asyncResult = $null
        
        while ($listener.IsListening) {
            try {
                # Start async operation if not already started
                if ($null -eq $asyncResult) {
                    $asyncResult = $listener.BeginGetContext($null, $null)
                }
                
                # Wait with timeout to allow interrupt checking
                $waitHandle = $asyncResult.AsyncWaitHandle
                if ($waitHandle.WaitOne(1000)) {
                    # Context is ready
                    $context = $listener.EndGetContext($asyncResult)
                    $asyncResult = $null
                    
                    $request = $context.Request
                    $path = $request.Url.AbsolutePath
                    
                    try {
                        if ($path -eq "/" -or $path -eq "") {
                            Send-TextResponse -Context $context -Text (Get-HtmlUI)
                        } elseif ($path -eq "/api/detect-paths") {
                            $python = Find-BootstrapPython
                            Send-JsonResponse -Context $context -Data @{
                                Python = if ($python.Count -gt 0) { $python[0].Path } else { $null }
                            }
                        } elseif ($path -eq "/api/setup-venv") {
                            Invoke-SetupVenvHandler -Context $context
                        } elseif ($path -eq "/api/build") {
                            Invoke-BuildHandler -Context $context
                        } elseif ($path -match "^/api/build-status/(.+)$") {
                            $buildId = $matches[1]
                            Invoke-BuildStatusHandler -Context $context -BuildId $buildId
                        } elseif ($path.StartsWith("/assets/")) {
                            # Serve static files from assets folder
                            $assetsPath = Resolve-Path (Join-Path $PSScriptRoot "..\assets") -ErrorAction SilentlyContinue
                            
                            if (-not $assetsPath) {
                                Send-TextResponse -Context $context -Text "Assets folder not found" -StatusCode 404
                            } else {
                                $fileName = $path.Substring("/assets/".Length)
                                
                                # Prevent path traversal attacks - reject any path with .. or absolute paths
                                if ($fileName -match '\.\.' -or [System.IO.Path]::IsPathRooted($fileName)) {
                                    Write-Host "Path traversal attempt blocked: $fileName" -ForegroundColor Red
                                    Send-TextResponse -Context $context -Text "Access denied" -StatusCode 403
                                } else {
                                    $filePath = Join-Path $assetsPath $fileName
                                    $resolvedFilePath = Resolve-Path $filePath -ErrorAction SilentlyContinue
                                    
                                    # Verify the resolved path is still within the assets directory
                                    if ($resolvedFilePath -and $resolvedFilePath.Path.StartsWith($assetsPath.Path, [StringComparison]::OrdinalIgnoreCase)) {
                                        if (Test-Path $resolvedFilePath -PathType Leaf) {
                                            try {
                                                $content = [System.IO.File]::ReadAllBytes($resolvedFilePath)
                                                $extension = [System.IO.Path]::GetExtension($resolvedFilePath).ToLower()
                                                $contentType = switch ($extension) {
                                                    ".png" { "image/png" }
                                                    ".jpg" { "image/jpeg" }
                                                    ".jpeg" { "image/jpeg" }
                                                    ".gif" { "image/gif" }
                                                    ".svg" { "image/svg+xml" }
                                                    default { "application/octet-stream" }
                                                }
                                                
                                                $response = $context.Response
                                                $response.StatusCode = 200
                                                $response.ContentType = $contentType
                                                $response.ContentLength64 = $content.Length
                                                $response.OutputStream.Write($content, 0, $content.Length)
                                                $response.OutputStream.Close()
                                            } catch {
                                                Write-Host "Error reading file: $_" -ForegroundColor Red
                                                Send-TextResponse -Context $context -Text "Error reading file" -StatusCode 500
                                            }
                                        } else {
                                            Send-TextResponse -Context $context -Text "File not found" -StatusCode 404
                                        }
                                    } else {
                                        Write-Host "Path traversal attempt blocked: $fileName" -ForegroundColor Red
                                        Send-TextResponse -Context $context -Text "Access denied" -StatusCode 403
                                    }
                                }
                            }
                        } else {
                            Send-TextResponse -Context $context -Text "Not Found" -StatusCode 404
                        }
                    } catch {
                        Write-Host "Error: $_" -ForegroundColor Red
                        try {
                            Send-TextResponse -Context $context -Text "Error: $($_.Exception.Message)" -StatusCode 500
                        } catch { }
                    }
                }
                # If timeout (WaitOne returns false), loop continues and checks if listener is still listening
            } catch [System.Net.HttpListenerException] {
                # Listener was stopped
                break
            } catch {
                if ($listener.IsListening) {
                    Write-Host "Error: $_" -ForegroundColor Red
                }
                Start-Sleep -Milliseconds 100
            }
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host ""
        Write-Info "Shutting down..."
    } finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        Write-Ok "Server stopped"
    }
}

Write-Info "PSUB - Python Security Update Builder"
Write-Info "========================"

if (-not (Test-Path $BuildScriptPath)) {
    Write-Host "Build script not found: $BuildScriptPath" -ForegroundColor Red
    exit 1
}

# Set up Ctrl+C handler
trap {
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException] -or
        $_.Exception.Message -match "canceled|aborted|interrupt") {
        Write-Host ""
        Write-Info "Shutting down..."
        if ($script:ServerListener -and $script:ServerListener.IsListening) {
            $script:ServerListener.Stop()
        }
        break
    }
    throw
}

Start-WebServer

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
    $batchFile = Join-Path $env:TEMP "python-build-$timestamp.bat"
    
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
) else (
    echo ========================================
    echo BUILD SUCCEEDED
    echo ========================================
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
    }
}

function Get-HtmlUI {
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Python Build</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: white;
            border-radius: 12px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #3776ab 0%, #4a90c2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; }
        .content { padding: 30px; }
        .section { margin-bottom: 30px; }
        .section h2 {
            color: #333;
            margin-bottom: 15px;
            font-size: 1.5em;
            border-bottom: 2px solid #3776ab;
            padding-bottom: 10px;
        }
        .form-group { margin-bottom: 20px; }
        .form-group label {
            display: block;
            margin-bottom: 5px;
            color: #555;
            font-weight: 500;
        }
        .form-row {
            display: flex;
            gap: 10px;
            align-items: flex-end;
        }
        .form-row input { flex: 1; }
        input[type="text"] {
            width: 100%;
            padding: 12px;
            border: 2px solid #e0e0e0;
            border-radius: 6px;
            font-size: 14px;
        }
        input[type="text"]:focus {
            outline: none;
            border-color: #3776ab;
        }
        .btn {
            padding: 12px 24px;
            border: none;
            border-radius: 6px;
            font-size: 14px;
            font-weight: 500;
            cursor: pointer;
            transition: all 0.3s;
        }
        .btn-primary {
            background: linear-gradient(135deg, #3776ab 0%, #4a90c2 100%);
            color: white;
        }
        .btn-primary:hover:not(:disabled) {
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(55, 118, 171, 0.4);
        }
        .btn-secondary {
            background: #6c757d;
            color: white;
        }
        .btn-secondary:hover { background: #5a6268; }
        .btn:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }
        .alert {
            padding: 15px;
            border-radius: 6px;
            margin-bottom: 20px;
        }
        .alert-success {
            background: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
        }
        .alert-error {
            background: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
        }
        .alert-info {
            background: #d1ecf1;
            color: #0c5460;
            border: 1px solid #bee5eb;
        }
        .hidden { display: none; }
        .note {
            background: #fff3cd;
            border: 1px solid #ffeeba;
            border-radius: 6px;
            padding: 15px;
            margin-bottom: 20px;
            color: #856404;
        }
        .note strong { display: block; margin-bottom: 5px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Python Build</h1>
            <p>Simple UI for building Python releases</p>
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
                } else {
                    showAlert('Failed to start build: ' + data.Error, 'error');
                }
            } catch (error) {
                showAlert('Error starting build: ' + error.message, 'error');
            } finally {
                btn.disabled = false;
                btn.textContent = 'Start Build (Opens New Window)';
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

Write-Info "Python Build - Simple UI"
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

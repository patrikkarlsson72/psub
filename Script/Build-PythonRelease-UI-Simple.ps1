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
$script:BuildStatusTtlHours = 24

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
    
    # Debug: Log JSON for prerequisites endpoint
    if ($Context.Request.Url.AbsolutePath -eq "/api/prerequisites") {
        Write-Host "[DEBUG] JSON Response (prerequisites): $($json.Substring(0, [Math]::Min(500, $json.Length)))..." -ForegroundColor Gray
    }
    
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

function Get-VsWherePath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
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

                    $vcvars = Join-Path $item.installationPath "VC\Auxiliary\Build\vcvars64.bat"
                    $installs += @{
                        Path = $item.installationPath
                        Version = $item.catalog.productDisplayVersion
                        Product = $item.catalog.productLineVersion
                        InstanceId = $item.instanceId
                        VcVars = $vcvars
                    }
                }
            }
        } catch {
            Write-Info "vswhere detection failed: $($_.Exception.Message)"
        }
    }

    if (@($installs).Count -eq 0) {
        # Legacy fallback when vswhere is unavailable
        $legacyPaths = @(
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community",
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional",
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise",
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Community",
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Professional",
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\Enterprise"
        )

        foreach ($legacyPath in $legacyPaths) {
            if (Test-Path $legacyPath) {
                $vcvars = Join-Path $legacyPath "VC\Auxiliary\Build\vcvars64.bat"
                $version = if ($legacyPath -match "\\(2019|2022)\\") { $matches[1] } else { "Unknown" }
                $installs += @{
                    Path = $legacyPath
                    Version = $version
                    Product = $version
                    InstanceId = $legacyPath
                    VcVars = $vcvars
                }
            }
        }
    }

    return @($installs | Sort-Object {
        try { [version]$_.Version } catch { [version]"0.0" }
    } -Descending)
}

function Find-VcVars64 {
    $installs = Get-VisualStudioInstallations

    foreach ($install in $installs) {
        if (Test-Path $install.VcVars) {
            return $install.VcVars
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
    
    Write-Host "[DEBUG] Searching for Bootstrap Python..." -ForegroundColor Cyan
    
    foreach ($pattern in $searchPaths) {
        Write-Host "[DEBUG] Searching pattern: $pattern" -ForegroundColor Gray
        try {
            $dirs = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue -Directory
            Write-Host "[DEBUG] Found $($dirs.Count) directories matching pattern" -ForegroundColor Gray
            foreach ($dir in $dirs) {
                $pythonExe = Join-Path $dir.FullName "python.exe"
                Write-Host "[DEBUG] Checking: $pythonExe" -ForegroundColor Gray
                if (Test-Path $pythonExe) {
                    try {
                        $versionOutput = & $pythonExe --version 2>&1
                        $versionStr = $versionOutput | Out-String
                        Write-Host "[DEBUG] Version output: $versionStr" -ForegroundColor Gray
                        
                        if ($versionStr -match 'Python\s+(\d+)\.(\d+)') {
                            $major = [int]$matches[1]
                            $minor = [int]$matches[2]
                            Write-Host "[DEBUG] Parsed version: $major.$minor" -ForegroundColor Gray
                            
                            # Accept Python 3.10 or 3.12 only
                            if (($major -eq 3) -and (($minor -eq 10) -or ($minor -eq 12))) {
                                Write-Host "[DEBUG] [OK] Found compatible Python: $pythonExe" -ForegroundColor Green
                                $found += @{
                                    Path = $pythonExe
                                    Version = "Python $major.$minor"
                                    Major = $major
                                    Minor = $minor
                                }
                            } else {
                                Write-Host "[DEBUG] [X] Incompatible version: $major.$minor (need 3.10 or 3.12)" -ForegroundColor Yellow
                            }
                        } else {
                            Write-Host "[DEBUG] [X] Could not parse version from: $versionStr" -ForegroundColor Yellow
                        }
                    } catch {
                        Write-Host "[DEBUG] [X] Version check failed: $_" -ForegroundColor Red
                    }
                } else {
                    Write-Host "[DEBUG] [X] python.exe not found at: $pythonExe" -ForegroundColor Gray
                }
            }
        } catch {
            Write-Host "[DEBUG] [X] Search path failed: $_" -ForegroundColor Red
        }
    }
    
    Write-Host "[DEBUG] Total compatible Python installations found: $($found.Count)" -ForegroundColor Cyan
    
    # Sort by version (prefer 3.12 over 3.10)
    return $found | Sort-Object { $_.Minor } -Descending
}

function Test-VisualStudio {
    $installs = Get-VisualStudioInstallations
    $supported = @($installs | Where-Object { $_.Product -in @("2019", "2022") })
    $selected = $supported | Select-Object -First 1

    if ($selected) {
        return @{
            Installed = $true
            Path = $selected.Path
            Version = $selected.Version
            Product = $selected.Product
            SupportedProducts = @("2019", "2022")
        }
    }

    return @{
        Installed = $false
        Path = $null
        Version = $null
        Product = $null
        SupportedProducts = @("2019", "2022")
    }
}

function Test-MSVCToolchains {
    $required = @("x64", "x86", "ARM64")
    $found = @()
    $missing = @()

    $toolchainDirs = @()
    foreach ($install in (Get-VisualStudioInstallations)) {
        $vcToolsPath = Join-Path $install.Path "VC\Tools\MSVC"
        if (Test-Path $vcToolsPath) {
            try {
                $dirs = Get-ChildItem -Path $vcToolsPath -ErrorAction SilentlyContinue -Directory | Where-Object {
                    $_.Name -match '^\d+\.\d+'
                }
                if ($dirs) {
                    $toolchainDirs += $dirs
                }
            } catch {
                Write-Info "Toolchain discovery failed for '$vcToolsPath': $($_.Exception.Message)"
            }
        }
    }

    if ($toolchainDirs) {
        $latestToolchain = $toolchainDirs | Sort-Object {
            try {
                [version]$_.Name
            } catch {
                [version]"0.0"
            }
        } -Descending | Select-Object -First 1

        $binPath = Join-Path $latestToolchain.FullName "bin\Hostx64"

        foreach ($arch in $required) {
            $archPath = Join-Path $binPath "x64"
            if ($arch -eq "x86") { $archPath = Join-Path $binPath "x86" }
            if ($arch -eq "ARM64") { $archPath = Join-Path $binPath "arm64" }

            $clPath = Join-Path $archPath "cl.exe"
            if (Test-Path $clPath) {
                $found += $arch
            } else {
                $missing += $arch
            }
        }
    } else {
        $missing = $required
    }

    return @{
        Found = $found
        Missing = $missing
        AllPresent = ($missing.Count -eq 0)
    }
}

function Test-Git {
    try {
        $gitCmd = Get-Command git -ErrorAction Stop
        $versionOutput = & git --version 2>&1
        $version = ($versionOutput | Out-String).Trim()
        return @{
            Installed = $true
            Version = $version
            Path = $gitCmd.Path
        }
    } catch {
        return @{
            Installed = $false
            Version = $null
            Path = $null
        }
    }
}

function Test-SafePathInput {
    param(
        [string]$Value,
        [string]$FieldName,
        [switch]$RequireExistingPath
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{ IsValid = $false; Error = "$FieldName is required" }
    }

    # Conservative allow-list to block cmd/powershell metacharacters.
    if ($Value -notmatch '^[a-zA-Z0-9_ .:\\()\-]+$') {
        return @{ IsValid = $false; Error = "$FieldName contains invalid characters" }
    }

    if ($RequireExistingPath -and -not (Test-Path $Value)) {
        return @{ IsValid = $false; Error = "$FieldName does not exist: $Value" }
    }

    return @{ IsValid = $true; Error = $null }
}

function Test-SafeSimpleName {
    param(
        [string]$Value,
        [string]$FieldName
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{ IsValid = $false; Error = "$FieldName is required" }
    }

    # Allow dots for names like "doc-venv3.10", but block traversal patterns.
    if ($Value -notmatch '^(?!.*\.\.)[a-zA-Z0-9_.-]{1,64}$') {
        return @{ IsValid = $false; Error = "$FieldName must match ^(?!.*\.\.)[a-zA-Z0-9_.-]{1,64}$" }
    }

    return @{ IsValid = $true; Error = $null }
}

function Cleanup-BuildStatus {
    $threshold = (Get-Date).AddHours(-$script:BuildStatusTtlHours)
    foreach ($id in @($script:BuildStatus.Keys)) {
        $entry = $script:BuildStatus[$id]
        if (-not $entry) {
            $script:BuildStatus.Remove($id) | Out-Null
            continue
        }

        if ($entry.StartTime -lt $threshold) {
            if ($entry.StatusFile -and (Test-Path $entry.StatusFile)) {
                Remove-Item -Path $entry.StatusFile -Force -ErrorAction SilentlyContinue
            }
            $script:BuildStatus.Remove($id) | Out-Null
        }
    }
}

function Test-WindowsSDK {
    $requiredVersion = "10.0.19041.0"
    $sdkPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Include"
    
    if (Test-Path $sdkPath) {
        $versions = Get-ChildItem -Path $sdkPath -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' }
        $found = $versions | Where-Object { $_.Name -eq $requiredVersion }
        
        # Also check if a later version is installed
        $laterVersions = $versions | Where-Object { 
            try {
                [version]$_.Name -ge [version]$requiredVersion
            } catch {
                $false
            }
        }
        
        # Check if found has any items (Where-Object returns empty array @() when no matches, not $null)
        $foundCount = @($found).Count
        $laterVersionsCount = @($laterVersions).Count
        
        return @{
            Installed = ($foundCount -gt 0 -or $laterVersionsCount -gt 0)
            Version = if ($foundCount -gt 0) { (@($found) | Select-Object -First 1).Name } elseif ($laterVersionsCount -gt 0) { ($laterVersions | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name } else { $null }
            RequiredVersion = $requiredVersion
            AvailableVersions = $versions | ForEach-Object { $_.Name }
        }
    }
    
    return @{
        Installed = $false
        Version = $null
        RequiredVersion = $requiredVersion
        AvailableVersions = @()
    }
}

function Invoke-PrerequisitesHandler {
    param([System.Net.HttpListenerContext]$Context)
    
    $vs = Test-VisualStudio
    $toolchains = Test-MSVCToolchains
    $sdk = Test-WindowsSDK
    $python = Find-BootstrapPython
    $git = Test-Git
    
    $result = @{
        VisualStudio = @{
            Installed = $vs.Installed
            Path = if ($vs.Installed) { $vs.Path } else { $null }
            Version = $vs.Version
            Product = $vs.Product
            SupportedProducts = $vs.SupportedProducts
        }
        MSVCToolchains = @{
            AllPresent = $toolchains.AllPresent
            Found = $toolchains.Found
            Missing = $toolchains.Missing
        }
        WindowsSDK = @{
            Installed = $sdk.Installed
            Version = $sdk.Version
            RequiredVersion = $sdk.RequiredVersion
            AvailableVersions = $sdk.AvailableVersions
        }
        BootstrapPython = @{
            Found = ($python.Count -gt 0)
            Versions = @($python | ForEach-Object { @{ Path = $_.Path; Version = $_.Version } })
        }
        Git = @{
            Installed = $git.Installed
            Version = $git.Version
            Path = $git.Path
        }
        AllReady = ($vs.Installed -and $toolchains.AllPresent -and $sdk.Installed -and ($python.Count -gt 0) -and $git.Installed)
    }
    
    Write-Host "[DEBUG] Bootstrap Python result: Found=$($result.BootstrapPython.Found), Versions count=$($result.BootstrapPython.Versions.Count)" -ForegroundColor Cyan
    if ($result.BootstrapPython.Versions.Count -gt 0) {
        Write-Host "[DEBUG] First version: $($result.BootstrapPython.Versions[0].Version) at $($result.BootstrapPython.Versions[0].Path)" -ForegroundColor Cyan
    }
    
    Send-JsonResponse -Context $Context -Data $result
}

function Invoke-DocumentationHandler {
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$DocName
    )
    
    $docPath = Join-Path $PSScriptRoot "..\documentation\$DocName.md"
    $resolvedPath = Resolve-Path $docPath -ErrorAction SilentlyContinue
    
    if (-not $resolvedPath) {
        Send-TextResponse -Context $Context -Text "Documentation not found: $DocName" -StatusCode 404
        return
    }
    
    # Prevent path traversal
    $docDir = Join-Path $PSScriptRoot "..\documentation"
    $resolvedDocDir = Resolve-Path $docDir -ErrorAction SilentlyContinue
    
    if (-not $resolvedDocDir) {
        Send-TextResponse -Context $Context -Text "Documentation directory not found" -StatusCode 404
        return
    }
    
    $normalizedDocDir = $resolvedDocDir.Path.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $normalizedResolvedPath = $resolvedPath.Path.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    
    if (-not $normalizedResolvedPath.StartsWith($normalizedDocDir, [StringComparison]::OrdinalIgnoreCase)) {
        Send-TextResponse -Context $Context -Text "Access denied" -StatusCode 403
        return
    }
    
    if (Test-Path $resolvedPath -PathType Leaf) {
        $content = Get-Content $resolvedPath -Raw
        
        # Escape the content for HTML (for use in textarea)
        $htmlEscapedContent = $content -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
        
        # Wrap in HTML page with Markdown renderer
        # Use a hidden textarea to store the markdown content safely
        $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$DocName - Documentation</title>
    <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 900px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        #content {
            background-color: white;
            padding: 40px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1, h2, h3, h4, h5, h6 {
            margin-top: 24px;
            margin-bottom: 16px;
            font-weight: 600;
            line-height: 1.25;
        }
        h1 { font-size: 2em; border-bottom: 1px solid #eaecef; padding-bottom: 10px; }
        h2 { font-size: 1.5em; border-bottom: 1px solid #eaecef; padding-bottom: 8px; }
        h3 { font-size: 1.25em; }
        p { margin-bottom: 16px; }
        ul, ol { margin-bottom: 16px; padding-left: 30px; }
        li { margin-bottom: 8px; }
        code {
            background-color: #f6f8fa;
            border-radius: 3px;
            padding: 2px 6px;
            font-family: 'Courier New', Consolas, monospace;
            font-size: 0.9em;
        }
        pre {
            background-color: #f6f8fa;
            border-radius: 6px;
            padding: 16px;
            overflow-x: auto;
            margin-bottom: 16px;
        }
        pre code {
            background-color: transparent;
            padding: 0;
        }
        blockquote {
            border-left: 4px solid #dfe2e5;
            padding-left: 16px;
            color: #6a737d;
            margin-bottom: 16px;
        }
        a {
            color: #0366d6;
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
        table {
            border-collapse: collapse;
            margin-bottom: 16px;
            width: 100%;
        }
        th, td {
            border: 1px solid #dfe2e5;
            padding: 6px 13px;
        }
        th {
            background-color: #f6f8fa;
            font-weight: 600;
        }
        strong { font-weight: 600; }
        em { font-style: italic; }
    </style>
</head>
<body>
    <div id="content"></div>
    <textarea id="markdown-source" style="display:none;">$htmlEscapedContent</textarea>
    <script>
        const markdown = document.getElementById('markdown-source').value;
        const html = marked.parse(markdown);
        document.getElementById('content').innerHTML = html;
    </script>
</body>
</html>
"@
        Send-TextResponse -Context $Context -Text $html -ContentType "text/html"
    } else {
        Send-TextResponse -Context $Context -Text "Documentation not found" -StatusCode 404
    }
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
    Cleanup-BuildStatus

    try {
        $body = Get-RequestBody -Context $Context
        $data = $body | ConvertFrom-Json
    } catch {
        Send-JsonResponse -Context $Context -Data @{
            Success = $false
            Code = "VALIDATION_ERROR"
            Error = "Invalid JSON payload"
        } -StatusCode 400
        return
    }

    $sourcePathValidation = Test-SafePathInput -Value $data.SourcePath -FieldName "SourcePath" -RequireExistingPath
    if (-not $sourcePathValidation.IsValid) {
        Send-JsonResponse -Context $Context -Data @{
            Success = $false
            Code = "VALIDATION_ERROR"
            Error = $sourcePathValidation.Error
        } -StatusCode 400
        return
    }

    $bootstrapValidation = Test-SafePathInput -Value $data.BootstrapPython -FieldName "BootstrapPython" -RequireExistingPath
    if (-not $bootstrapValidation.IsValid) {
        Send-JsonResponse -Context $Context -Data @{
            Success = $false
            Code = "VALIDATION_ERROR"
            Error = $bootstrapValidation.Error
        } -StatusCode 400
        return
    }

    $venvName = if ($data.VenvName) { $data.VenvName } else { "doc-venv" }
    $venvValidation = Test-SafeSimpleName -Value $venvName -FieldName "VenvName"
    if (-not $venvValidation.IsValid) {
        Send-JsonResponse -Context $Context -Data @{
            Success = $false
            Code = "VALIDATION_ERROR"
            Error = $venvValidation.Error
        } -StatusCode 400
        return
    }

    $releaseRoot = if ($data.ReleaseRoot) { $data.ReleaseRoot } else { "C:\python-releases" }
    $releaseRootValidation = Test-SafePathInput -Value $releaseRoot -FieldName "ReleaseRoot"
    if (-not $releaseRootValidation.IsValid) {
        Send-JsonResponse -Context $Context -Data @{
            Success = $false
            Code = "VALIDATION_ERROR"
            Error = $releaseRootValidation.Error
        } -StatusCode 400
        return
    }

    $winSdkVersion = if ($data.WinSdkVersion) { $data.WinSdkVersion } else { "10.0.19041.0" }
    if ($winSdkVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        Send-JsonResponse -Context $Context -Data @{
            Success = $false
            Code = "VALIDATION_ERROR"
            Error = "WinSdkVersion must be in the format 10.0.19041.0"
        } -StatusCode 400
        return
    }

    $vcvarsPath = Find-VcVars64
    if (-not $vcvarsPath) {
        Send-JsonResponse -Context $Context -Data @{
            Success = $false
            Code = "BUILD_START_ERROR"
            Error = "Visual Studio C++ build tools (2019/2022) not found"
        } -StatusCode 400
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $buildId = [guid]::NewGuid().ToString()
    $batchFile = Join-Path $env:TEMP "python-build-$timestamp.bat"
    $statusFile = Join-Path $env:TEMP "python-build-status-$buildId.txt"
    $logsDir = Join-Path $PSScriptRoot "..\logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    $logPath = Join-Path $logsDir "build-$buildId.log"

    $script:BuildStatus[$buildId] = @{
        Status = "running"
        StartTime = Get-Date
        StatusFile = $statusFile
        LogPath = $logPath
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$BuildScriptPath" -SourcePath "$($data.SourcePath)" -BootstrapPython "$($data.BootstrapPython)" -VenvName "$venvName" -ReleaseRoot "$releaseRoot" -WinSdkVersion "$winSdkVersion" -BuildId "$buildId" -LogPath "$logPath"
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

    try {
        Set-Content -Path $batchFile -Value $batchContent -Encoding ASCII
        Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$batchFile`"")
    } catch {
        Send-JsonResponse -Context $Context -Data @{
            Success = $false
            Code = "BUILD_START_ERROR"
            Error = "Failed to start build: $($_.Exception.Message)"
        } -StatusCode 500
        return
    }

    Send-JsonResponse -Context $Context -Data @{
        Success = $true
        Message = "Build started in new window"
        BuildId = $buildId
        LogPath = $logPath
    }
}

function Invoke-BuildStatusHandler {
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$BuildId
    )

    Cleanup-BuildStatus

    if (-not $script:BuildStatus.ContainsKey($BuildId)) {
        Send-JsonResponse -Context $Context -Data @{ 
            Status = "unknown"
            Message = "Build ID not found"
        } -StatusCode 404
        return
    }
    
    $buildInfo = $script:BuildStatus[$BuildId]
    $statusFile = $buildInfo.StatusFile
    
    $logPath = $buildInfo.LogPath
    $lastErrorSnippet = $null
    if ($logPath -and (Test-Path $logPath)) {
        try {
            $lastErrorSnippet = Get-Content -Path $logPath -Tail 100 | Select-String -Pattern 'FAIL|ERROR' | Select-Object -Last 1 | ForEach-Object { $_.Line }
        } catch {
            $lastErrorSnippet = $null
        }
    }

    if (Test-Path $statusFile) {
        $status = Get-Content $statusFile -Raw
        $status = $status.Trim()
        
        $script:BuildStatus[$BuildId].Status = $status
        
        Send-JsonResponse -Context $Context -Data @{
            Status = $status
            Message = if ($status -eq "success") { "Build completed successfully" } else { "Build failed" }
            LogPath = $logPath
            LastErrorSnippet = $lastErrorSnippet
        }
    } else {
        Send-JsonResponse -Context $Context -Data @{
            Status = "running"
            Message = "Build is still running"
            LogPath = $logPath
            LastErrorSnippet = $lastErrorSnippet
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
        .prereq-panel {
            background: rgba(248, 249, 250, 0.9);
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
        }
        .prereq-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px;
            margin-bottom: 10px;
            background: white;
            border-radius: 6px;
            border-left: 4px solid #ddd;
        }
        .prereq-item.ready {
            border-left-color: #28a745;
        }
        .prereq-item.not-ready {
            border-left-color: #dc3545;
        }
        .prereq-item .status-icon {
            font-size: 1.2em;
            margin-right: 10px;
        }
        .prereq-item .status-icon.ready::before {
            content: "\2713";
            color: #28a745;
        }
        .prereq-item .status-icon.not-ready::before {
            content: "\2717";
            color: #dc3545;
        }
        .help-link {
            margin-left: 10px;
            color: #3776ab;
            text-decoration: none;
            font-size: 0.9em;
            border-bottom: 1px dotted #3776ab;
        }
        .help-link:hover {
            color: #2b5d88;
            border-bottom: 1px solid #2b5d88;
        }
        .help-link::after {
            content: " \2197";
            font-size: 0.8em;
        }
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
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
                <h2>Prerequisites</h2>
                <div class="prereq-panel" id="prereqPanel">
                    <div style="text-align: center; padding: 20px;">
                        <div style="display: inline-block; width: 16px; height: 16px; border: 3px solid rgba(55, 118, 171, 0.3); border-radius: 50%; border-top-color: #3776ab; animation: spin 1s linear infinite; margin-right: 8px;"></div>
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
                
                console.log('[DEBUG] detectPaths response:', data);
                console.log('[DEBUG] data.Python:', data.Python);
                console.log('[DEBUG] data.Python type:', typeof data.Python);
                
                if (data.Python) {
                    document.getElementById('bootstrapPython').value = data.Python;
                    showAlert('Python path auto-detected', 'success');
                } else {
                    showAlert('No compatible Python found', 'error');
                }
            } catch (error) {
                console.error('[DEBUG] detectPaths error:', error);
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
                    const extraError = data.LastErrorSnippet ? (' Last error: ' + data.LastErrorSnippet) : '';
                    showAlert('Build failed. Check terminal window/log for details.' + extraError, 'error');
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
                    const errorCode = data.Code ? (' [' + data.Code + ']') : '';
                    showAlert('Failed to start build' + errorCode + ': ' + data.Error, 'error');
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
        
        async function checkPrerequisites() {
            const panel = document.getElementById('prereqPanel');
            panel.innerHTML = '<div style="text-align: center; padding: 20px;"><div style="display: inline-block; width: 16px; height: 16px; border: 3px solid rgba(55, 118, 171, 0.3); border-radius: 50%; border-top-color: #3776ab; animation: spin 1s linear infinite; margin-right: 8px;"></div><span>Checking prerequisites...</span></div>';
            
            try {
                const response = await fetch('/api/prerequisites');
                const data = await response.json();
                
                // Debug: Log the response data
                console.log('[DEBUG] Prerequisites response:', data);
                console.log('[DEBUG] BootstrapPython:', data.BootstrapPython);
                console.log('[DEBUG] Versions:', data.BootstrapPython.Versions);
                console.log('[DEBUG] Versions type:', typeof data.BootstrapPython.Versions);
                console.log('[DEBUG] Versions length:', data.BootstrapPython.Versions ? data.BootstrapPython.Versions.length : 'undefined');
                
                let html = '';
                
                // Visual Studio
                const vsStatus = data.VisualStudio.Installed ? 'ready' : 'not-ready';
                const vsIcon = data.VisualStudio.Installed ? 'ready' : 'not-ready';
                const vsPath = data.VisualStudio.Installed
                    ? ((data.VisualStudio.Path || 'Installed') + (data.VisualStudio.Version ? (' (v' + data.VisualStudio.Version + ')') : ''))
                    : 'Not Found';
                let vsHelpLink = '';
                if (!data.VisualStudio.Installed) {
                    vsHelpLink = '<a href="/api/docs/setup_visual_studio" target="_blank" class="help-link">Setup Guide</a>';
                }
                html += '<div class="prereq-item ' + vsStatus + '">' +
                    '<div><span class="status-icon ' + vsIcon + '"></span><strong>Visual Studio (2019/2022)</strong></div>' +
                    '<div>' + vsPath + vsHelpLink + '</div>' +
                    '</div>';
                
                // MSVC Toolchains
                const toolchainStatus = data.MSVCToolchains.AllPresent ? 'ready' : 'not-ready';
                const toolchainIcon = data.MSVCToolchains.AllPresent ? 'ready' : 'not-ready';
                const toolchainMsg = data.MSVCToolchains.AllPresent 
                    ? 'All toolchains present' 
                    : ('Missing: ' + data.MSVCToolchains.Missing.join(', '));
                let toolchainHelpLink = '';
                if (!data.MSVCToolchains.AllPresent) {
                    toolchainHelpLink = '<a href="/api/docs/setup_visual_studio" target="_blank" class="help-link">Setup Guide</a>';
                }
                html += '<div class="prereq-item ' + toolchainStatus + '">' +
                    '<div><span class="status-icon ' + toolchainIcon + '"></span><strong>MSVC Toolchains (v142)</strong></div>' +
                    '<div>' + toolchainMsg + toolchainHelpLink + '</div>' +
                    '</div>';
                
                // Windows SDK
                const sdkStatus = data.WindowsSDK.Installed ? 'ready' : 'not-ready';
                const sdkIcon = data.WindowsSDK.Installed ? 'ready' : 'not-ready';
                const sdkMsg = data.WindowsSDK.Installed ? 
                    ('Version ' + data.WindowsSDK.Version) : 
                    ('Required: ' + data.WindowsSDK.RequiredVersion);
                let sdkHelpLink = '';
                if (!data.WindowsSDK.Installed) {
                    sdkHelpLink = '<a href="/api/docs/setup_windows_sdk" target="_blank" class="help-link">Setup Guide</a>';
                }
                html += '<div class="prereq-item ' + sdkStatus + '">' +
                    '<div><span class="status-icon ' + sdkIcon + '"></span><strong>Windows SDK</strong></div>' +
                    '<div>' + sdkMsg + sdkHelpLink + '</div>' +
                    '</div>';
                
                // Bootstrap Python
                const pythonStatus = data.BootstrapPython.Found ? 'ready' : 'not-ready';
                const pythonIcon = data.BootstrapPython.Found ? 'ready' : 'not-ready';
                const pythonVersionsArray = data.BootstrapPython.Versions || [];
                const pythonMsg = data.BootstrapPython.Found ? 
                    (pythonVersionsArray.length + ' version(s) found') : 
                    'Not Found';
                let pythonHelpLink = '';
                if (!data.BootstrapPython.Found) {
                    pythonHelpLink = '<a href="/api/docs/setup_bootstrap_python" target="_blank" class="help-link">Setup Guide</a>';
                }
                html += '<div class="prereq-item ' + pythonStatus + '">' +
                    '<div><span class="status-icon ' + pythonIcon + '"></span><strong>Bootstrap Python (3.10/3.12)</strong></div>' +
                    '<div>' + pythonMsg + pythonHelpLink + '</div>' +
                    '</div>';

                // Git for Windows
                const gitStatus = data.Git.Installed ? 'ready' : 'not-ready';
                const gitIcon = data.Git.Installed ? 'ready' : 'not-ready';
                const gitMsg = data.Git.Installed ? (data.Git.Version || 'Installed') : 'Not Found';
                let gitHelpLink = '';
                if (!data.Git.Installed) {
                    gitHelpLink = '<a href="/api/docs/setup_git" target="_blank" class="help-link">Setup Guide</a>';
                }
                html += '<div class="prereq-item ' + gitStatus + '">' +
                    '<div><span class="status-icon ' + gitIcon + '"></span><strong>Git for Windows</strong></div>' +
                    '<div>' + gitMsg + gitHelpLink + '</div>' +
                    '</div>';
                
                if (data.AllReady) {
                    html += '<div class="alert alert-success" style="margin-top: 15px;">All prerequisites are ready! You can proceed with the build.</div>';
                } else {
                    html += '<div class="alert alert-error" style="margin-top: 15px;">Some prerequisites are missing. Click the "Setup Guide" links above for installation instructions.</div>';
                }
                
                panel.innerHTML = html;
            } catch (error) {
                panel.innerHTML = '<div class="alert alert-error">Error checking prerequisites: ' + error.message + '</div>';
            }
        }
        
        // Auto-detect on load
        checkPrerequisites();
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
                Cleanup-BuildStatus

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
                        } elseif ($path -eq "/api/prerequisites") {
                            Invoke-PrerequisitesHandler -Context $context
                        } elseif ($path -eq "/api/detect-paths") {
                            $python = @(Find-BootstrapPython)
                            Write-Host "[DEBUG] /api/detect-paths - Python type: $($python.GetType().Name)" -ForegroundColor Cyan
                            Write-Host "[DEBUG] /api/detect-paths - Python count: $($python.Count)" -ForegroundColor Cyan
                            Write-Host "[DEBUG] /api/detect-paths - Python value: $python" -ForegroundColor Cyan
                            if ($python.Count -gt 0) {
                                Write-Host "[DEBUG] /api/detect-paths - First element type: $($python[0].GetType().Name)" -ForegroundColor Cyan
                                Write-Host "[DEBUG] /api/detect-paths - First Python Path: $($python[0].Path)" -ForegroundColor Cyan
                            }
                            $pythonPath = if ($python.Count -gt 0) { $python[0].Path } else { $null }
                            Write-Host "[DEBUG] /api/detect-paths - Returning: $pythonPath" -ForegroundColor Cyan
                            Send-JsonResponse -Context $context -Data @{
                                Python = $pythonPath
                            }
                        } elseif ($path -match "^/api/docs/(.+)$") {
                            $docName = $matches[1]
                            Invoke-DocumentationHandler -Context $context -DocName $docName
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
                                    $filePath = Join-Path $assetsPath.Path $fileName
                                    $resolvedFilePath = Resolve-Path $filePath -ErrorAction SilentlyContinue
                                    
                                    # Verify the resolved path is still within the assets directory
                                    # Ensure proper directory boundary checking by normalizing paths with trailing separator
                                    $normalizedAssetsPath = $assetsPath.Path.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                                    $normalizedResolvedPath = $resolvedFilePath.Path.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                                    
                                    if ($resolvedFilePath -and $normalizedResolvedPath.StartsWith($normalizedAssetsPath, [StringComparison]::OrdinalIgnoreCase)) {
                                        if (Test-Path $resolvedFilePath -PathType Leaf) {
                                            try {
                                                $content = [System.IO.File]::ReadAllBytes($resolvedFilePath.Path)
                                                $extension = [System.IO.Path]::GetExtension($resolvedFilePath.Path).ToLower()
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

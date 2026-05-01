#requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$ReleaseRoot = "C:\python-releases",
    [string]$ReleaseDir = "",
    [string]$BootstrapPython = "",
    [string]$VenvName = "doc-venv"
)

$ErrorActionPreference = "Stop"

function Resolve-RequiredPath {
    param(
        [string]$Path,
        [string]$Label
    )

    try {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    } catch {
        throw "$Label not found: $Path"
    }
}

function Get-CommandPathOrEmpty {
    param([string]$Name)

    try {
        $cmd = Get-Command $Name -ErrorAction Stop
        return $cmd.Source
    } catch {
        return ""
    }
}

function Get-CommandOutputOrEmpty {
    param(
        [string]$Command,
        [string[]]$Arguments = @()
    )

    try {
        return ((& $Command @Arguments 2>&1) | Out-String).Trim()
    } catch {
        return ""
    }
}

function Get-FileHashTable {
    param([string]$Path)

    $resolved = Resolve-RequiredPath -Path $Path -Label "File"
    $hash = Get-FileHash -LiteralPath $resolved -Algorithm SHA256
    return [ordered]@{
        Path = $resolved
        SHA256 = $hash.Hash
    }
}

function Get-LatestReleaseDirectory {
    param([string]$Root)

    $resolvedRoot = Resolve-RequiredPath -Path $Root -Label "ReleaseRoot"
    $latest = Get-ChildItem -LiteralPath $resolvedRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No release directories found under '$resolvedRoot'"
    }

    return $latest.FullName
}

function Get-PatchlevelVersion {
    param([string]$SourceRoot)

    $patchlevelPath = Join-Path $SourceRoot "Include\patchlevel.h"
    if (-not (Test-Path -LiteralPath $patchlevelPath)) {
        return ""
    }

    $content = Get-Content -LiteralPath $patchlevelPath -Raw
    $major = ([regex]::Match($content, '#define\s+PY_MAJOR_VERSION\s+(\d+)')).Groups[1].Value
    $minor = ([regex]::Match($content, '#define\s+PY_MINOR_VERSION\s+(\d+)')).Groups[1].Value
    $micro = ([regex]::Match($content, '#define\s+PY_MICRO_VERSION\s+(\d+)')).Groups[1].Value
    $level = ([regex]::Match($content, '#define\s+PY_RELEASE_LEVEL\s+(PY_RELEASE_LEVEL_[A-Z]+)')).Groups[1].Value
    $serial = ([regex]::Match($content, '#define\s+PY_RELEASE_SERIAL\s+(\d+)')).Groups[1].Value

    if (-not $major -or -not $minor -or -not $micro) {
        return ""
    }

    $suffix = switch ($level) {
        "PY_RELEASE_LEVEL_ALPHA" { "a$serial" }
        "PY_RELEASE_LEVEL_BETA" { "b$serial" }
        "PY_RELEASE_LEVEL_GAMMA" { "rc$serial" }
        default { "" }
    }

    return "$major.$minor.$micro$suffix"
}

function Get-PipFreezeOutput {
    param([string]$PythonPath)

    if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath)) {
        return ""
    }

    return Get-CommandOutputOrEmpty -Command $PythonPath -Arguments @("-m", "pip", "freeze")
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedSourcePath = Resolve-RequiredPath -Path $SourcePath -Label "SourcePath"
$resolvedReleaseRoot = Resolve-RequiredPath -Path $ReleaseRoot -Label "ReleaseRoot"
$resolvedReleaseDir = if ($ReleaseDir) {
    Resolve-RequiredPath -Path $ReleaseDir -Label "ReleaseDir"
} else {
    Get-LatestReleaseDirectory -Root $resolvedReleaseRoot
}

$releaseZipPath = "$resolvedReleaseDir.zip"
if (-not (Test-Path -LiteralPath $releaseZipPath)) {
    $candidateZip = Get-ChildItem -LiteralPath $resolvedReleaseRoot -File -Filter "*.zip" |
        Where-Object { $_.BaseName -eq (Split-Path -Leaf $resolvedReleaseDir) } |
        Select-Object -First 1
    $releaseZipPath = if ($candidateZip) { $candidateZip.FullName } else { "" }
}

$evidenceDir = Join-Path $resolvedReleaseDir "_evidence"
if (-not (Test-Path -LiteralPath $evidenceDir)) {
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
}

$venvPath = Join-Path $resolvedSourcePath $VenvName
$venvPythonPath = Join-Path $venvPath "Scripts\python.exe"
$pipPath = Join-Path $venvPath "Scripts\pip.exe"
$sphinxBuildPath = Join-Path $venvPath "Scripts\sphinx-build.exe"
$bootstrapPythonResolved = if ($BootstrapPython) {
    Resolve-RequiredPath -Path $BootstrapPython -Label "BootstrapPython"
} else {
    ""
}

$gitPath = Get-CommandPathOrEmpty -Name "git"
$gitVersion = if ($gitPath) { Get-CommandOutputOrEmpty -Command $gitPath -Arguments @("--version") } else { "" }
$repoCommit = if ($gitPath) { Get-CommandOutputOrEmpty -Command $gitPath -Arguments @("-C", $repoRoot, "rev-parse", "HEAD") } else { "" }
$repoStatus = if ($gitPath) { Get-CommandOutputOrEmpty -Command $gitPath -Arguments @("-C", $repoRoot, "status", "--short") } else { "" }

$bootstrapVersion = if ($bootstrapPythonResolved) {
    Get-CommandOutputOrEmpty -Command $bootstrapPythonResolved -Arguments @("--version")
} else {
    ""
}

$venvPythonVersion = if (Test-Path -LiteralPath $venvPythonPath) {
    Get-CommandOutputOrEmpty -Command $venvPythonPath -Arguments @("--version")
} else {
    ""
}

$pipVersion = if (Test-Path -LiteralPath $pipPath) {
    Get-CommandOutputOrEmpty -Command $pipPath -Arguments @("--version")
} else {
    ""
}

$sphinxVersion = if (Test-Path -LiteralPath $sphinxBuildPath) {
    Get-CommandOutputOrEmpty -Command $sphinxBuildPath -Arguments @("--version")
} else {
    ""
}

$pipFreeze = Get-PipFreezeOutput -PythonPath $venvPythonPath

$artifactFiles = Get-ChildItem -LiteralPath $resolvedReleaseDir -Recurse -File |
    Where-Object { $_.FullName -notlike "$evidenceDir*" }

$artifactHashes = @()
foreach ($file in $artifactFiles) {
    $artifactHashes += [pscustomobject](Get-FileHashTable -Path $file.FullName)
}

if ($releaseZipPath -and (Test-Path -LiteralPath $releaseZipPath)) {
    $artifactHashes += [pscustomobject](Get-FileHashTable -Path $releaseZipPath)
}

$metadata = [ordered]@{
    GeneratedAt = (Get-Date).ToString("o")
    MachineName = $env:COMPUTERNAME
    UserName = $env:USERNAME
    RepoRoot = $repoRoot
    RepoCommit = $repoCommit
    RepoDirty = [bool]($repoStatus)
    SourcePath = $resolvedSourcePath
    SourceVersion = (Get-PatchlevelVersion -SourceRoot $resolvedSourcePath)
    ReleaseRoot = $resolvedReleaseRoot
    ReleaseDir = $resolvedReleaseDir
    ReleaseZip = $releaseZipPath
    BootstrapPythonPath = $bootstrapPythonResolved
    BootstrapPythonVersion = $bootstrapVersion
    VenvPath = $venvPath
    VenvPythonPath = if (Test-Path -LiteralPath $venvPythonPath) { $venvPythonPath } else { "" }
    VenvPythonVersion = $venvPythonVersion
    PipPath = if (Test-Path -LiteralPath $pipPath) { $pipPath } else { "" }
    PipVersion = $pipVersion
    SphinxBuildPath = if (Test-Path -LiteralPath $sphinxBuildPath) { $sphinxBuildPath } else { "" }
    SphinxVersion = $sphinxVersion
    GitPath = $gitPath
    GitVersion = $gitVersion
}

$metadataPath = Join-Path $evidenceDir "build-metadata.json"
$pipFreezePath = Join-Path $evidenceDir "pip-freeze.txt"
$hashesPath = Join-Path $evidenceDir "artifact-sha256.txt"
$summaryPath = Join-Path $evidenceDir "summary.txt"

$metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding ASCII
$pipFreeze | Set-Content -LiteralPath $pipFreezePath -Encoding ASCII

$hashLines = foreach ($entry in $artifactHashes) {
    "{0}  {1}" -f $entry.SHA256, $entry.Path
}
$hashLines | Set-Content -LiteralPath $hashesPath -Encoding ASCII

$summary = @(
    "PSUB Build Evidence"
    "GeneratedAt: $($metadata.GeneratedAt)"
    "RepoCommit: $($metadata.RepoCommit)"
    "RepoDirty: $($metadata.RepoDirty)"
    "SourceVersion: $($metadata.SourceVersion)"
    "ReleaseDir: $($metadata.ReleaseDir)"
    "ReleaseZip: $($metadata.ReleaseZip)"
    "BootstrapPythonVersion: $($metadata.BootstrapPythonVersion)"
    "VenvPythonVersion: $($metadata.VenvPythonVersion)"
    "PipVersion: $($metadata.PipVersion)"
    "SphinxVersion: $($metadata.SphinxVersion)"
    "HashFile: $hashesPath"
    "PipFreezeFile: $pipFreezePath"
    "MetadataFile: $metadataPath"
)
$summary | Set-Content -LiteralPath $summaryPath -Encoding ASCII

Write-Host "[OK] Evidence written to $evidenceDir" -ForegroundColor Green
Write-Host "[INFO] Summary: $summaryPath" -ForegroundColor Cyan

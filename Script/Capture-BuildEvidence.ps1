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

function ConvertTo-HtmlSafeText {
    param([string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return [System.Net.WebUtility]::HtmlEncode(($Value | Out-String).Trim())
}

function Get-EvidenceDisplayValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "Not available"
    }

    return $Value
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
$summaryHtmlPath = Join-Path $evidenceDir "summary.html"

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

$artifactCount = @($artifactHashes).Count
$releaseDirName = Split-Path -Leaf $resolvedReleaseDir
$releaseZipName = if ($releaseZipPath) { Split-Path -Leaf $releaseZipPath } else { "" }
$summaryTitle = "PSUB Build Evidence Summary"
$summarySubtitle = "Executive summary for release evidence captured from the local build environment."
$htmlMetadataRows = @(
    @{ Label = "Generated At"; Value = $metadata.GeneratedAt }
    @{ Label = "Source Version"; Value = $metadata.SourceVersion }
    @{ Label = "Release Directory"; Value = $metadata.ReleaseDir }
    @{ Label = "Release Zip"; Value = (Get-EvidenceDisplayValue -Value $metadata.ReleaseZip) }
    @{ Label = "Repository Commit"; Value = (Get-EvidenceDisplayValue -Value $metadata.RepoCommit) }
    @{ Label = "Repository Dirty"; Value = [string]$metadata.RepoDirty }
    @{ Label = "Bootstrap Python"; Value = (Get-EvidenceDisplayValue -Value $metadata.BootstrapPythonVersion) }
    @{ Label = "Venv Python"; Value = (Get-EvidenceDisplayValue -Value $metadata.VenvPythonVersion) }
    @{ Label = "pip"; Value = (Get-EvidenceDisplayValue -Value $metadata.PipVersion) }
    @{ Label = "Sphinx"; Value = (Get-EvidenceDisplayValue -Value $metadata.SphinxVersion) }
)

$metadataRowsHtml = ($htmlMetadataRows | ForEach-Object {
    "<tr><th>{0}</th><td>{1}</td></tr>" -f (ConvertTo-HtmlSafeText -Value $_.Label), (ConvertTo-HtmlSafeText -Value $_.Value)
}) -join [Environment]::NewLine

$evidenceLinks = @(
    @{ Label = "Build metadata (JSON)"; FileName = [System.IO.Path]::GetFileName($metadataPath); Note = "Machine-readable build metadata." }
    @{ Label = "Artifact SHA256 list"; FileName = [System.IO.Path]::GetFileName($hashesPath); Note = "Checksums for release artifacts." }
    @{ Label = "pip freeze"; FileName = [System.IO.Path]::GetFileName($pipFreezePath); Note = "Installed Python package versions inside the venv." }
    @{ Label = "Technical text summary"; FileName = [System.IO.Path]::GetFileName($summaryPath); Note = "Plain-text overview for quick terminal review." }
)

$evidenceLinksHtml = ($evidenceLinks | ForEach-Object {
    $href = ConvertTo-HtmlSafeText -Value $_.FileName
    $label = ConvertTo-HtmlSafeText -Value $_.Label
    $note = ConvertTo-HtmlSafeText -Value $_.Note
    "<li><a href=""{0}"">{1}</a><span>{2}</span></li>" -f $href, $label, $note
}) -join [Environment]::NewLine

$releaseZipDisplay = ConvertTo-HtmlSafeText -Value (Get-EvidenceDisplayValue -Value $releaseZipName)
$releaseDirDisplay = ConvertTo-HtmlSafeText -Value $releaseDirName
$artifactCountDisplay = ConvertTo-HtmlSafeText -Value ([string]$artifactCount)
$htmlTitleDisplay = ConvertTo-HtmlSafeText -Value $summaryTitle
$htmlSubtitleDisplay = ConvertTo-HtmlSafeText -Value $summarySubtitle

$summaryHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$htmlTitleDisplay</title>
    <style>
        :root {
            color-scheme: light;
        }
        * {
            box-sizing: border-box;
        }
        body {
            margin: 0;
            font-family: "Segoe UI", Tahoma, Arial, sans-serif;
            background: #f4f7fb;
            color: #1f2d3d;
            line-height: 1.5;
        }
        .page {
            max-width: 980px;
            margin: 0 auto;
            padding: 32px 20px 48px;
        }
        .report {
            background: #ffffff;
            border: 1px solid #d7e1ec;
            border-radius: 14px;
            box-shadow: 0 10px 30px rgba(15, 23, 42, 0.08);
            overflow: hidden;
        }
        .hero {
            padding: 28px 32px 22px;
            background: linear-gradient(180deg, #f8fbff 0%, #edf4fb 100%);
            border-bottom: 1px solid #d7e1ec;
        }
        .eyebrow {
            display: inline-block;
            margin-bottom: 10px;
            padding: 4px 10px;
            border-radius: 999px;
            background: #dcecff;
            color: #1f4f82;
            font-size: 12px;
            font-weight: 700;
            letter-spacing: 0.04em;
            text-transform: uppercase;
        }
        h1 {
            margin: 0 0 8px;
            font-size: 30px;
            line-height: 1.15;
            color: #162538;
        }
        .subtitle {
            margin: 0;
            font-size: 15px;
            color: #4a6178;
            max-width: 760px;
        }
        .section {
            padding: 24px 32px 8px;
        }
        .section h2 {
            margin: 0 0 14px;
            font-size: 18px;
            color: #163252;
        }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
            gap: 14px;
        }
        .summary-card {
            border: 1px solid #d9e5f1;
            border-radius: 10px;
            padding: 14px 16px;
            background: #fbfdff;
        }
        .summary-card .label {
            display: block;
            margin-bottom: 6px;
            font-size: 12px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.04em;
            color: #5f7891;
        }
        .summary-card .value {
            font-size: 16px;
            font-weight: 700;
            color: #18324f;
            word-break: break-word;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            border: 1px solid #d9e5f1;
            border-radius: 10px;
            overflow: hidden;
        }
        th, td {
            padding: 12px 14px;
            border-bottom: 1px solid #e3ebf3;
            text-align: left;
            vertical-align: top;
        }
        th {
            width: 240px;
            background: #f8fbff;
            color: #33516d;
            font-size: 13px;
            font-weight: 700;
        }
        td {
            color: #1f2d3d;
            font-size: 14px;
            word-break: break-word;
        }
        tr:last-child th,
        tr:last-child td {
            border-bottom: none;
        }
        .file-list {
            list-style: none;
            padding: 0;
            margin: 0;
            display: grid;
            gap: 10px;
        }
        .file-list li {
            border: 1px solid #d9e5f1;
            border-radius: 10px;
            padding: 12px 14px;
            background: #fbfdff;
        }
        .file-list a {
            color: #0f5ea8;
            font-weight: 700;
            text-decoration: none;
        }
        .file-list a:hover {
            text-decoration: underline;
        }
        .file-list span {
            display: block;
            margin-top: 4px;
            font-size: 13px;
            color: #5a7188;
        }
        .footer-note {
            padding: 18px 32px 28px;
            font-size: 13px;
            color: #5a7188;
        }
        @media (max-width: 640px) {
            .page {
                padding: 16px 12px 28px;
            }
            .hero, .section, .footer-note {
                padding-left: 18px;
                padding-right: 18px;
            }
            h1 {
                font-size: 24px;
            }
            th {
                width: 38%;
            }
        }
    </style>
</head>
<body>
    <div class="page">
        <div class="report">
            <div class="hero">
                <div class="eyebrow">PSUB Evidence</div>
                <h1>$htmlTitleDisplay</h1>
                <p class="subtitle">$htmlSubtitleDisplay</p>
            </div>

            <div class="section">
                <h2>Release Snapshot</h2>
                <div class="summary-grid">
                    <div class="summary-card">
                        <span class="label">Source Version</span>
                        <span class="value">$(ConvertTo-HtmlSafeText -Value (Get-EvidenceDisplayValue -Value $metadata.SourceVersion))</span>
                    </div>
                    <div class="summary-card">
                        <span class="label">Release Folder</span>
                        <span class="value">$releaseDirDisplay</span>
                    </div>
                    <div class="summary-card">
                        <span class="label">Release Zip</span>
                        <span class="value">$releaseZipDisplay</span>
                    </div>
                    <div class="summary-card">
                        <span class="label">Artifacts Hashed</span>
                        <span class="value">$artifactCountDisplay</span>
                    </div>
                </div>
            </div>

            <div class="section">
                <h2>Build Metadata</h2>
                <table>
                    <tbody>
$metadataRowsHtml
                    </tbody>
                </table>
            </div>

            <div class="section">
                <h2>Evidence Files</h2>
                <ul class="file-list">
$evidenceLinksHtml
                </ul>
            </div>

            <div class="footer-note">
                This document is a presentation-friendly summary of the local build evidence bundle. Detailed technical evidence remains available in the linked files above.
            </div>
        </div>
    </div>
</body>
</html>
"@

$summaryHtml | Set-Content -LiteralPath $summaryHtmlPath -Encoding ASCII

Write-Host "[OK] Evidence written to $evidenceDir" -ForegroundColor Green
Write-Host "[INFO] Summary: $summaryPath" -ForegroundColor Cyan
Write-Host "[INFO] HTML Summary: $summaryHtmlPath" -ForegroundColor Cyan

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet("cpp", "rust", "all")]
    [string]$Implementation = "all",

    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildType = "Release",

    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "first-rpc\bin"),

    [switch]$SkipPathUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-CppBinaries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$BuildType
    )

    $buildDir = switch ($BuildType) {
        "Debug" { "cmake-build-debug" }
        default { "cmake-build-release" }
    }

    $names = @("first_rpc_server.exe", "first_rpc_client.exe")
    $resolved = @()
    foreach ($name in $names) {
        $candidates = @(
            (Join-Path $RepoRoot "$buildDir\$BuildType\$name"),
            (Join-Path $RepoRoot "$buildDir\$name")
        )

        $match = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $match) {
            throw "Unable to find $name for build type $BuildType. Run .\build.ps1 first."
        }
        $resolved += $match
    }

    return $resolved
}

function Resolve-RustBinaries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$BuildType
    )

    $profileDir = if ($BuildType -eq "Debug") { "debug" } else { "release" }
    $names = @("first_rpc_server_rust.exe", "first_rpc_client_rust.exe")
    $resolved = @()
    foreach ($name in $names) {
        $candidate = Join-Path $RepoRoot "rust\target\$profileDir\$name"
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "Unable to find $name for build type $BuildType. Run .\rust\rust_build.ps1 first."
        }
        $resolved += $candidate
    }

    return $resolved
}

function Ensure-PathContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir
    )

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $segments = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $segments = $userPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    }

    $alreadyPresent = $segments | Where-Object { $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\') }
    if (-not $alreadyPresent) {
        $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
            $InstallDir
        } else {
            "$userPath;$InstallDir"
        }
        [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
        Write-Host "Added install directory to user PATH: $InstallDir" -ForegroundColor Yellow
    } else {
        Write-Host "Install directory already exists in user PATH: $InstallDir" -ForegroundColor DarkGray
    }

    $processSegments = $env:Path.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    $processPresent = $processSegments | Where-Object { $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\') }
    if (-not $processPresent) {
        $env:Path = "$InstallDir;$env:Path"
    }
}

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$resolvedFiles = @()

if ($Implementation -in @("cpp", "all")) {
    $resolvedFiles += Resolve-CppBinaries -RepoRoot $RepoRoot -BuildType $BuildType
}

if ($Implementation -in @("rust", "all")) {
    $resolvedFiles += Resolve-RustBinaries -RepoRoot $RepoRoot -BuildType $BuildType
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

foreach ($file in $resolvedFiles) {
    $destination = Join-Path $InstallDir (Split-Path -Leaf $file)
    if ($PSCmdlet.ShouldProcess($destination, "Install $(Split-Path -Leaf $file)")) {
        Copy-Item -LiteralPath $file -Destination $destination -Force
        Write-Host "Installed $(Split-Path -Leaf $file) -> $destination" -ForegroundColor Green
    }
}

if (-not $SkipPathUpdate) {
    if ($PSCmdlet.ShouldProcess($InstallDir, "Add install directory to user PATH")) {
        Ensure-PathContains -InstallDir $InstallDir
    }
}

Write-Host ""
Write-Host "Available commands:" -ForegroundColor Cyan
$resolvedFiles |
    ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } |
    Sort-Object -Unique |
    ForEach-Object { Write-Host "  $_" }

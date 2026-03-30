param(
    [ValidateSet("Debug", "Release")]
    [string]$BuildType = "Release",

    [string]$HttpProxy = "http://127.0.0.1:7897",

    [switch]$RunTests,

    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Host "==> $Name" -ForegroundColor Cyan
    & $Action
}

function Assert-CommandExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $CommandName"
    }
}

$RustRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RustManifest = Join-Path $RustRoot "Cargo.toml"

Assert-CommandExists -CommandName "cargo"

if (-not [string]::IsNullOrWhiteSpace($HttpProxy)) {
    $env:HTTP_PROXY = $HttpProxy
    $env:HTTPS_PROXY = $HttpProxy
    Write-Host "Using proxy: $HttpProxy" -ForegroundColor DarkGray
}

Push-Location $RustRoot
try {
    if (-not $SkipBuild) {
        Invoke-Step -Name "Build Rust binaries" -Action {
            if ($BuildType -eq "Release") {
                cargo build --release --manifest-path $RustManifest
            } else {
                cargo build --manifest-path $RustManifest
            }
        }
    }

    if ($RunTests) {
        Invoke-Step -Name "Run Rust unit tests" -Action {
            cargo test --manifest-path $RustManifest
        }
    }

    Write-Host "Rust build completed." -ForegroundColor Green
} finally {
    Pop-Location
}

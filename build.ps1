param(
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildType = "Release",

    [string]$Generator = "Visual Studio 18 2026",

    [ValidateSet("x64", "Win32", "ARM64")]
    [string]$Architecture = "x64",

    [string]$HttpProxy = "http://127.0.0.1:7897",

    [switch]$SkipConanProfileDetect,
    [switch]$SkipConanInstall,
    [switch]$SkipConfigure,
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

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildDir = Join-Path $RepoRoot "build"

Assert-CommandExists -CommandName "conan"
Assert-CommandExists -CommandName "cmake"

if (-not [string]::IsNullOrWhiteSpace($HttpProxy)) {
    $env:HTTP_PROXY = $HttpProxy
    $env:HTTPS_PROXY = $HttpProxy
    Write-Host "Using proxy: $HttpProxy" -ForegroundColor DarkGray
}

if (-not (Test-Path -LiteralPath $BuildDir)) {
    New-Item -ItemType Directory -Path $BuildDir | Out-Null
}

Push-Location $RepoRoot
try {
    if (-not $SkipConanProfileDetect) {
        Invoke-Step -Name "Detect Conan profile" -Action {
            conan profile detect --force
        }
    }

    if (-not $SkipConanInstall) {
        Invoke-Step -Name "Install Conan dependencies" -Action {
            conan install . `
                --output-folder=build `
                --build=missing `
                -s:h build_type=$BuildType `
                -s:h compiler.cppstd=23 `
                -s:b build_type=$BuildType `
                -s:b compiler.cppstd=23
        }
    }

    if (-not $SkipConfigure) {
        Invoke-Step -Name "Configure CMake" -Action {
            cmake -S . -B build `
                -G $Generator `
                -A $Architecture `
                -DCMAKE_TOOLCHAIN_FILE="$BuildDir\conan_toolchain.cmake" `
                -DCMAKE_POLICY_DEFAULT_CMP0091=NEW `
                -DCMAKE_BUILD_TYPE=$BuildType
        }
    }

    if (-not $SkipBuild) {
        Invoke-Step -Name "Build solution" -Action {
            cmake --build build --config $BuildType
        }
    }

    Write-Host "Build completed." -ForegroundColor Green
} finally {
    Pop-Location
}

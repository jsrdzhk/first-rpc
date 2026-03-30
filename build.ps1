param(
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildType = "Release",

    [string]$Generator = "Visual Studio 17 2022",

    [ValidateSet("x64", "Win32", "ARM64")]
    [string]$Architecture = "x64",

    [string]$HttpProxy = "http://127.0.0.1:7897",

    [int]$Parallel = [Environment]::ProcessorCount,

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

$BuildDirName = switch ($BuildType) {
    "Debug" { "cmake-build-debug" }
    "Release" { "cmake-build-release" }
    "RelWithDebInfo" { "cmake-build-release" }
    "MinSizeRel" { "cmake-build-release" }
    default { "cmake-build-release" }
}

$BuildDir = Join-Path $RepoRoot $BuildDirName
$GrpcInstallDir = Join-Path $RepoRoot ("third_party\\grpc-install\\windows-" + $BuildType.ToLowerInvariant())
$GrpcConfigCandidates = @(
    (Join-Path $GrpcInstallDir "lib\\cmake\\grpc\\gRPCConfig.cmake"),
    (Join-Path $GrpcInstallDir "cmake\\grpc\\gRPCConfig.cmake")
)
$ProtobufConfigCandidates = @(
    (Join-Path $GrpcInstallDir "lib\\cmake\\protobuf\\protobuf-config.cmake"),
    (Join-Path $GrpcInstallDir "lib\\cmake\\protobuf\\ProtobufConfig.cmake"),
    (Join-Path $GrpcInstallDir "cmake\\protobuf\\protobuf-config.cmake"),
    (Join-Path $GrpcInstallDir "cmake\\protobuf\\ProtobufConfig.cmake")
)

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
    if (-not (Test-Path -LiteralPath $GrpcInstallDir)) {
        throw "Local gRPC install not found in $GrpcInstallDir. Run .\deps.ps1 -BuildType $BuildType first."
    }

    $HasGrpcConfig = ($GrpcConfigCandidates | Where-Object { Test-Path -LiteralPath $_ } | Measure-Object).Count -gt 0
    $HasProtobufConfig = ($ProtobufConfigCandidates | Where-Object { Test-Path -LiteralPath $_ } | Measure-Object).Count -gt 0

    if (-not $HasGrpcConfig -or -not $HasProtobufConfig) {
        throw "Local gRPC install in $GrpcInstallDir is incomplete. Expected gRPC/Protobuf CMake config files were not found. Re-run .\deps.ps1 -BuildType $BuildType and let the install step finish."
    }

    if (-not $SkipConfigure) {
        Invoke-Step -Name "Configure CMake" -Action {
            cmake -S . -B $BuildDirName `
                -G $Generator `
                -A $Architecture `
                -DFIRST_RPC_GRPC_ROOT="$GrpcInstallDir" `
                -DCMAKE_PREFIX_PATH="$GrpcInstallDir;$GrpcInstallDir\\lib\\cmake;$GrpcInstallDir\\cmake" `
                -DCMAKE_PROGRAM_PATH="$GrpcInstallDir\\bin" `
                -DCMAKE_BUILD_TYPE=$BuildType
        }
    }

    if (-not $SkipBuild) {
        Invoke-Step -Name "Build solution" -Action {
            cmake --build $BuildDirName --config $BuildType --parallel $Parallel
        }
    }

    Write-Host "Build completed." -ForegroundColor Green
} finally {
    Pop-Location
}

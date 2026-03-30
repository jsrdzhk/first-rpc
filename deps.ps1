param(
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildType = "Release",

    [string]$Generator = "Visual Studio 17 2022",

    [ValidateSet("x64", "Win32", "ARM64")]
    [string]$Architecture = "x64",

    [string]$HttpProxy = "http://127.0.0.1:7897",

    [string]$GrpcVersion = "v1.78.1",

    [switch]$SkipClone,
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
$ThirdPartyRoot = Join-Path $RepoRoot "third_party"
$GrpcSourceDir = Join-Path $ThirdPartyRoot "grpc-src"
$BuildSuffix = "windows-" + $BuildType.ToLowerInvariant()
$GrpcBuildDir = Join-Path $ThirdPartyRoot ("grpc-build\\" + $BuildSuffix)
$GrpcInstallDir = Join-Path $ThirdPartyRoot ("grpc-install\\" + $BuildSuffix)
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

Assert-CommandExists -CommandName "git"
Assert-CommandExists -CommandName "cmake"

if (-not [string]::IsNullOrWhiteSpace($HttpProxy)) {
    $env:HTTP_PROXY = $HttpProxy
    $env:HTTPS_PROXY = $HttpProxy
    Write-Host "Using proxy: $HttpProxy" -ForegroundColor DarkGray
}

foreach ($dir in @($ThirdPartyRoot, $GrpcBuildDir, $GrpcInstallDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
}

Push-Location $RepoRoot
try {
    if (-not $SkipClone) {
        if (-not (Test-Path -LiteralPath $GrpcSourceDir)) {
            Invoke-Step -Name "Clone gRPC source" -Action {
                git clone --recurse-submodules -b $GrpcVersion --depth 1 --shallow-submodules https://github.com/grpc/grpc $GrpcSourceDir
            }
        } else {
            Invoke-Step -Name "Update gRPC submodules" -Action {
                git -C $GrpcSourceDir submodule update --init --recursive
            }
        }
    }

    Invoke-Step -Name "Configure gRPC" -Action {
        cmake -S $GrpcSourceDir -B $GrpcBuildDir `
            -G $Generator `
            -A $Architecture `
            -DgRPC_INSTALL=ON `
            -DgRPC_BUILD_TESTS=OFF `
            -DABSL_PROPAGATE_CXX_STD=ON `
            -DCMAKE_CXX_STANDARD=20 `
            -DCMAKE_INSTALL_PREFIX="$GrpcInstallDir"
    }

    if (-not $SkipBuild) {
        Invoke-Step -Name "Build and install gRPC" -Action {
            cmake --build $GrpcBuildDir --config $BuildType --target install -j 4
        }

        $HasGrpcConfig = ($GrpcConfigCandidates | Where-Object { Test-Path -LiteralPath $_ } | Measure-Object).Count -gt 0
        $HasProtobufConfig = ($ProtobufConfigCandidates | Where-Object { Test-Path -LiteralPath $_ } | Measure-Object).Count -gt 0

        if (-not $HasGrpcConfig -or -not $HasProtobufConfig) {
            throw "gRPC install finished but package config files were not found under $GrpcInstallDir. Re-run .\deps.ps1 and make sure the install step completes successfully."
        }

        Write-Host "gRPC installed to $GrpcInstallDir" -ForegroundColor Green
    } else {
        Write-Host "gRPC configure completed. Build/install skipped." -ForegroundColor Yellow
    }
} finally {
    Pop-Location
}

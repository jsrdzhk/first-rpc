param(
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildType = "Release",

    [string]$Generator = "Visual Studio 17 2022",

    [ValidateSet("x64", "Win32", "ARM64")]
    [string]$Architecture = "x64",

    [string]$HttpProxy = "http://127.0.0.1:7897",

    [string]$GrpcVersion = "",

    [int]$Parallel = [Environment]::ProcessorCount,

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

function Get-GitOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    if ($output -is [array]) {
        return ($output -join "`n").Trim()
    }

    return ([string]$output).Trim()
}

function Resolve-GrpcRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,
        [string]$RequestedRef
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedRef)) {
        return $RequestedRef
    }

    $tags = Get-GitOutput -Arguments @("-C", $RepoPath, "tag", "--list", "v*", "--sort=-version:refname")
    if ([string]::IsNullOrWhiteSpace($tags)) {
        throw "Unable to resolve the latest stable gRPC tag in $RepoPath"
    }

    $stableTag = $tags -split "`r?`n" |
        Where-Object { $_ -match "^v\d+\.\d+\.\d+$" } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($stableTag)) {
        throw "No stable non-pre gRPC tag was found in $RepoPath"
    }

    return $stableTag
}

function Resolve-GitDefaultBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath
    )

    $RemoteHeadRef = Get-GitOutput -Arguments @("-C", $RepoPath, "symbolic-ref", "refs/remotes/origin/HEAD")
    if (-not [string]::IsNullOrWhiteSpace($RemoteHeadRef)) {
        return ($RemoteHeadRef -replace "^refs/remotes/origin/", "")
    }

    & git -C $RepoPath remote set-head origin --auto *> $null

    $RemoteHeadRef = Get-GitOutput -Arguments @("-C", $RepoPath, "symbolic-ref", "refs/remotes/origin/HEAD")
    if (-not [string]::IsNullOrWhiteSpace($RemoteHeadRef)) {
        return ($RemoteHeadRef -replace "^refs/remotes/origin/", "")
    }

    foreach ($candidate in @("master", "main")) {
        $branchExists = Get-GitOutput -Arguments @("-C", $RepoPath, "ls-remote", "--heads", "origin", $candidate)
        if (-not [string]::IsNullOrWhiteSpace($branchExists)) {
            return $candidate
        }
    }

    throw "Unable to determine origin default branch for $RepoPath"
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
                git clone --recurse-submodules https://github.com/grpc/grpc $GrpcSourceDir
            }
        }

        Invoke-Step -Name "Pull latest gRPC default branch" -Action {
            git -C $GrpcSourceDir fetch --prune --tags --all
            $DefaultBranch = Resolve-GitDefaultBranch -RepoPath $GrpcSourceDir
            git -C $GrpcSourceDir checkout -B $DefaultBranch "origin/$DefaultBranch"
            git -C $GrpcSourceDir pull --ff-only origin $DefaultBranch
        }

        Invoke-Step -Name "Switch gRPC source to resolved ref" -Action {
            $ResolvedGrpcRef = Resolve-GrpcRef -RepoPath $GrpcSourceDir -RequestedRef $GrpcVersion
            $RemoteBranchSha = Get-GitOutput -Arguments @("-C", $GrpcSourceDir, "ls-remote", "--heads", "origin", $ResolvedGrpcRef)
            if (-not [string]::IsNullOrWhiteSpace($RemoteBranchSha)) {
                git -C $GrpcSourceDir checkout -B $ResolvedGrpcRef "origin/$ResolvedGrpcRef"
                git -C $GrpcSourceDir pull --ff-only origin $ResolvedGrpcRef
            } else {
                git -C $GrpcSourceDir checkout $ResolvedGrpcRef
            }

            Write-Host "Resolved gRPC ref: $ResolvedGrpcRef" -ForegroundColor DarkGray
        }

        Invoke-Step -Name "Update gRPC submodules" -Action {
            git -C $GrpcSourceDir submodule update --init --recursive
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
            cmake --build $GrpcBuildDir --config $BuildType --target install --parallel $Parallel
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

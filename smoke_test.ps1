param(
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildType = "Release",

    [string]$ServerHost = "127.0.0.1",

    [int]$Port = 18777,

    [string]$Token = "smoke-token"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-BinaryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$BuildType,
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $buildDir = switch ($BuildType) {
        "Debug" { "cmake-build-debug" }
        default { "cmake-build-release" }
    }

    $candidates = @(
        (Join-Path $RepoRoot "$buildDir\$BuildType\$Name.exe"),
        (Join-Path $RepoRoot "$buildDir\$Name.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Unable to find binary $Name.exe for build type $BuildType. Run .\build.ps1 first."
}

function Invoke-Client {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & $ClientPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Client command failed: $($Arguments -join ' ')`n$output"
    }
    return [string]::Join("`n", $output)
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not $Text.Contains($Expected)) {
        throw "$Label did not contain expected text: $Expected`nActual output:`n$Text"
    }
}

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerPath = Resolve-BinaryPath -Name "first_rpc_server" -BuildType $BuildType -RepoRoot $RepoRoot
$ClientPath = Resolve-BinaryPath -Name "first_rpc_client" -BuildType $BuildType -RepoRoot $RepoRoot

$SmokeRoot = Join-Path $RepoRoot "build\smoke-test"
$ServerStdoutLog = Join-Path $SmokeRoot "server.stdout.log"
$ServerStderrLog = Join-Path $SmokeRoot "server.stderr.log"
$SampleFile = Join-Path $SmokeRoot "sample.log"

New-Item -ItemType Directory -Force -Path $SmokeRoot | Out-Null
@(
    "alpha line"
    "beta line"
    "ERROR target line"
    "omega line"
) | Set-Content -LiteralPath $SampleFile -Encoding utf8

$server = $null

try {
    $server = Start-Process -FilePath $ServerPath `
        -ArgumentList @("--host", $ServerHost, "--port", "$Port", "--root", $SmokeRoot, "--token", $Token) `
        -PassThru `
        -RedirectStandardOutput $ServerStdoutLog `
        -RedirectStandardError $ServerStderrLog `
        -WindowStyle Hidden

    Start-Sleep -Seconds 2

    $commonArgs = @("--host", $ServerHost, "--port", "$Port", "--token", $Token)

    $health = Invoke-Client -ClientPath $ClientPath -Arguments ($commonArgs + @("health_check"))
    Assert-Contains -Text $health -Expected "ok: true" -Label "health_check"
    Assert-Contains -Text $health -Expected "summary: server is healthy" -Label "health_check"

    $listDir = Invoke-Client -ClientPath $ClientPath -Arguments ($commonArgs + @("list_dir", "--path", "."))
    Assert-Contains -Text $listDir -Expected "sample.log" -Label "list_dir"

    $readFile = Invoke-Client -ClientPath $ClientPath -Arguments ($commonArgs + @("read_file", "--path", "sample.log"))
    Assert-Contains -Text $readFile -Expected "ERROR target line" -Label "read_file"

    $tailFile = Invoke-Client -ClientPath $ClientPath -Arguments ($commonArgs + @("tail_file", "--path", "sample.log", "--lines", "2"))
    Assert-Contains -Text $tailFile -Expected "ERROR target line" -Label "tail_file"
    Assert-Contains -Text $tailFile -Expected "omega line" -Label "tail_file"

    $grepFile = Invoke-Client -ClientPath $ClientPath -Arguments ($commonArgs + @("grep_file", "--path", "sample.log", "--needle", "ERROR"))
    Assert-Contains -Text $grepFile -Expected "ERROR target line" -Label "grep_file"

    Write-Host "Smoke test passed." -ForegroundColor Green
} finally {
    if ($null -ne $server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
    }
}

# Mole Windows - signs the release assets the workflow built.
#
# Runs on Windows with the maintainer's code-signing certificate available,
# for example a Certum cloud certificate after a SimplySign Desktop login.
# It signs every .ps1 and .exe inside mole-<version>-x64.zip and the two raw
# TUI executables, verifies each signature and its timestamp, rebuilds the zip
# and rewrites SHA256SUMS.txt. Nothing is uploaded; see RELEASE.md.
#
#   $env:MOLE_SIGN_PARAMS = "/fd sha256 /tr http://time.certum.pl /td sha256 /sha1 <thumbprint>"
#   .\scripts\sign-release.ps1 -Path C:\path\to\downloaded\assets

#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [string]$Path,

    # signtool arguments placed between "sign" and the file name.
    [string]$SignParams = $env:MOLE_SIGN_PARAMS,

    # Optional explicit signtool.exe; otherwise an x64 copy is located.
    [string]$SignTool = $env:MOLE_SIGNTOOL
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$tuiAssets = @("analyze-windows-x64.exe", "status-windows-x64.exe")

function Get-PeMachine {
    param([string]$File)
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $peOffset = [BitConverter]::ToInt32($bytes, 60)
    return [BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

# A cloud HSM's key storage provider is usually x64 only, and an ARM64
# signtool cannot load it, so only an x64 (0x8664) signtool is accepted.
function Resolve-SignTool {
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) {
            throw "MOLE_SIGNTOOL points to a missing file: $Explicit"
        }
        return $Explicit
    }

    $roots = @(
        "$env:USERPROFILE\.nuget\packages\microsoft.windows.sdk.buildtools",
        "$env:USERPROFILE\.dotnet\tools\.store\vpk",
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        $candidates = Get-ChildItem -LiteralPath $root -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending
        foreach ($candidate in $candidates) {
            if ((Get-PeMachine -File $candidate.FullName) -eq 0x8664) {
                return $candidate.FullName
            }
        }
    }
    throw "No x64 signtool.exe found. Install the Windows SDK build tools or set MOLE_SIGNTOOL."
}

function Invoke-SignFile {
    param(
        [string]$Tool,
        [string[]]$Arguments,
        [string]$File
    )

    # Timestamp servers sometimes return an answer signtool cannot parse; one
    # retry covers that, and a second failure stops the release.
    # Windows PowerShell turns native stderr into an error record, which
    # "Stop" would make fatal before the retry; judge by the exit code instead.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $output = & $Tool sign @Arguments $File 2>&1
            if ($LASTEXITCODE -eq 0) {
                return
            }
            Write-Host "  signtool failed on attempt ${attempt}: $(($output | ForEach-Object { "$_" }) -join ' ')" -ForegroundColor Yellow
        }
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    throw "Could not sign $File"
}

function Assert-Signature {
    param(
        [string]$File,
        [string]$Thumbprint
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $File
    if ($signature.Status -ne "Valid") {
        throw "Signature on $File is $($signature.Status)"
    }
    if ($Thumbprint -and $signature.SignerCertificate.Thumbprint -ne $Thumbprint) {
        throw "Signature on $File uses certificate $($signature.SignerCertificate.Thumbprint), expected $Thumbprint"
    }
    if (-not $signature.TimeStamperCertificate) {
        throw "Signature on $File has no timestamp"
    }
}

if (-not $SignParams) {
    throw "Set MOLE_SIGN_PARAMS to the signtool arguments, for example '/fd sha256 /tr http://time.certum.pl /td sha256 /sha1 <thumbprint>'."
}
$signArguments = @($SignParams -split '\s+' | Where-Object { $_ })
$thumbprint = $null
$sha1Index = [Array]::IndexOf($signArguments, "/sha1")
if ($sha1Index -ge 0 -and $sha1Index + 1 -lt $signArguments.Count) {
    $thumbprint = $signArguments[$sha1Index + 1].ToUpperInvariant()
}

$assetDir = (Resolve-Path -LiteralPath $Path).ProviderPath
$zips = @(Get-ChildItem -LiteralPath $assetDir -Filter "mole-*-x64.zip" -File)
if ($zips.Count -ne 1) {
    throw "Expected exactly one mole-<version>-x64.zip in $assetDir, found $($zips.Count)"
}
$zip = $zips[0]
foreach ($asset in $tuiAssets) {
    if (-not (Test-Path -LiteralPath (Join-Path $assetDir $asset))) {
        throw "Missing release asset: $asset"
    }
}

$tool = Resolve-SignTool -Explicit $SignTool
Write-Host "signtool: $tool"

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mole-sign-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workDir | Out-Null
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $workDir)

    # The raw TUI assets and their copies under bin\ are the same build; sign
    # the raw file once and reuse those bytes so both downloads match.
    $bundledCopies = @{
        "analyze-windows-x64.exe" = Join-Path $workDir "bin\analyze.exe"
        "status-windows-x64.exe"  = Join-Path $workDir "bin\status.exe"
    }
    $reused = @{}
    foreach ($asset in $tuiAssets) {
        $raw = Join-Path $assetDir $asset
        Write-Host "Signing $asset"
        Invoke-SignFile -Tool $tool -Arguments $signArguments -File $raw
        Assert-Signature -File $raw -Thumbprint $thumbprint
        $copy = $bundledCopies[$asset]
        if (Test-Path -LiteralPath $copy) {
            Copy-Item -LiteralPath $raw -Destination $copy -Force
            $reused[$copy] = $true
        }
    }

    $toSign = @(Get-ChildItem -LiteralPath $workDir -Recurse -File |
        Where-Object { $_.Extension -in ".ps1", ".psm1", ".psd1", ".exe" -and -not $reused.ContainsKey($_.FullName) })
    foreach ($file in $toSign) {
        Write-Host "Signing $($file.FullName.Substring($workDir.Length + 1))"
        Invoke-SignFile -Tool $tool -Arguments $signArguments -File $file.FullName
        Assert-Signature -File $file.FullName -Thumbprint $thumbprint
    }
    foreach ($copy in $reused.Keys) {
        Assert-Signature -File $copy -Thumbprint $thumbprint
    }

    $signedZip = "$($zip.FullName).signed"
    if (Test-Path -LiteralPath $signedZip) {
        Remove-Item -LiteralPath $signedZip -Force
    }
    & (Join-Path $PSScriptRoot "new-release-zip.ps1") -SourceDir $workDir -Destination $signedZip
    Move-Item -LiteralPath $signedZip -Destination $zip.FullName -Force

    & (Join-Path $PSScriptRoot "write-checksums.ps1") -Directory $assetDir -Files (@($zip.Name) + $tuiAssets)

    Write-Host ""
    Write-Host "Signed $($toSign.Count + $reused.Count) files inside $($zip.Name) and $($tuiAssets.Count) TUI assets." -ForegroundColor Green
    Write-Host "Upload the files in $assetDir to the draft release, then publish it." -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Mole Windows - writes a release zip whose entry names use forward slashes.
#
# Windows PowerShell's Compress-Archive and .NET Framework's
# ZipFile.CreateFromDirectory store "bin\analyze.exe". The zip format expects
# "bin/analyze.exe", and winget's archive check rejects a backslash name as a
# malformed archive ("Archive scan detected malware"), so build the archive
# entry by entry and verify it before returning.

#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [string]$SourceDir,

    [Parameter(Mandatory)]
    [string]$Destination
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = (Resolve-Path -LiteralPath $SourceDir).ProviderPath.TrimEnd('\')
if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Destination -Force
}

$stream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName)) {
            $name = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
            $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $name, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally {
        $archive.Dispose()
    }
}
finally {
    $stream.Dispose()
}

$check = [System.IO.Compression.ZipFile]::OpenRead($Destination)
try {
    $bad = @($check.Entries | Where-Object { $_.FullName.Contains('\') })
}
finally {
    $check.Dispose()
}
if ($bad.Count -gt 0) {
    throw "Zip entry names must use forward slashes: $($bad[0].FullName)"
}

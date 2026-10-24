# Real sinks run only inside Pester's isolated fixture tree.
BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . "$repo\lib\clean\caches.ps1"
    . "$repo\lib\clean\dev.ps1"
    $script:SavedCacheEnvironment = @{}
    foreach ($name in @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'MO_NO_OPLOG')) {
        $script:SavedCacheEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $script:SavedCacheWhitelist = $script:Config.WhitelistFile
    $script:SavedCacheGuard = $script:MoleCleanPathGuard
    $script:SavedCacheDryRun = $script:MoleDryRunMode
    function New-CacheFile([string]$Path) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [IO.File]::WriteAllText($Path, 'cache fixture')
        return $Path
    }
}
AfterAll {
    foreach ($name in $script:SavedCacheEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedCacheEnvironment[$name])
    }
    $script:Config.WhitelistFile = $script:SavedCacheWhitelist
    $script:MoleCleanPathGuard = $script:SavedCacheGuard
    $script:MoleDryRunMode = $script:SavedCacheDryRun
}

Describe 'Application cache boundaries' {
    BeforeEach {
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0,8))
        $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'Local'
        $env:APPDATA = Join-Path $env:USERPROFILE 'Roaming'
        $env:MO_NO_OPLOG = '1'
        $script:Config.WhitelistFile = Join-Path $env:USERPROFILE 'whitelist.txt'
        $script:ExportListFile = Join-Path $env:USERPROFILE 'preview.txt'
        $script:MoleCleanPathGuard = $true
        Set-DryRunMode -Enabled $false
        Reset-CleanupStats
        Mock Get-Process { @() }
        Mock Invoke-MoleOwnerCacheCleanup {}
        Mock Start-Section {}
        Mock Stop-Section {}
    }

    It 'Keeps Poetry virtualenvs while cleaning its two disposable children' {
        $root = "$env:LOCALAPPDATA\pypoetry\Cache"
        $venv = New-CacheFile "$root\virtualenvs\project\Scripts\python.exe"
        $artifact = New-CacheFile "$root\artifacts\a.whl"
        $cache = New-CacheFile "$root\cache\repo\entry"
        Set-DryRunMode -Enabled $true
        Clear-PythonCaches
        Test-Path -LiteralPath $artifact | Should -BeTrue
        Test-Path -LiteralPath $venv | Should -BeTrue
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match 'virtualenvs'
        Set-DryRunMode -Enabled $false
        Clear-PythonCaches
        Test-Path -LiteralPath $venv | Should -BeTrue
        Test-Path -LiteralPath $artifact | Should -BeFalse
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'Keeps offline CacheStorage beside an eligible Slack disk cache' {
        $offline = New-CacheFile "$env:APPDATA\Slack\Service Worker\CacheStorage\offline"
        $cache = New-CacheFile "$env:APPDATA\Slack\Cache\entry"
        Clear-AppCaches
        Test-Path -LiteralPath $offline | Should -BeTrue
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'Cleans every Chromium profile for <Brand> and preserves offline data' -ForEach @(
        @{Brand='Chrome'; Relative='Google\Chrome\User Data'},
        @{Brand='Edge'; Relative='Microsoft\Edge\User Data'},
        @{Brand='Brave'; Relative='BraveSoftware\Brave-Browser\User Data'},
        @{Brand='Vivaldi'; Relative='Vivaldi\User Data'}
    ) {
        $root = Join-Path $env:LOCALAPPDATA $Relative
        $files = @(foreach ($profile in @('Default','Profile 2','Profile [work]')) {
            foreach ($leaf in @('Cache','Code Cache','GPUCache')) { New-CacheFile "$root\$profile\$leaf\entry" }
        })
        $offline = New-CacheFile "$root\Default\Service Worker\CacheStorage\offline"
        $cookie = New-CacheFile "$root\Profile 2\Cookies"
        Clear-BrowserCaches
        foreach ($file in $files) { Test-Path -LiteralPath $file | Should -BeFalse }
        Test-Path -LiteralPath $offline | Should -BeTrue
        Test-Path -LiteralPath $cookie | Should -BeTrue
    }

    It 'Uses Firefox local caches and keeps its roaming profile stores' {
        $cache = New-CacheFile "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\p.default\cache2\entry"
        $shader = New-CacheFile "$env:APPDATA\Mozilla\Firefox\Profiles\p.default\shader-cache\entry"
        $profile = New-CacheFile "$env:APPDATA\Mozilla\Firefox\Profiles\p.default\cache2\kept"
        Clear-BrowserCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        Test-Path -LiteralPath $shader | Should -BeFalse
        Test-Path -LiteralPath $profile | Should -BeTrue
    }

    It 'Cleans exact application caches for <Folder> and keeps authored state' -ForEach @(
        @{Folder='Cursor'}, @{Folder='Windsurf'}, @{Folder='obsidian'}, @{Folder='Notion'}
    ) {
        $cache = New-CacheFile "$env:APPDATA\$Folder\Code Cache\entry"
        $state = New-CacheFile "$env:APPDATA\$Folder\User\workspaceStorage\state"
        $offline = New-CacheFile "$env:APPDATA\$Folder\Service Worker\CacheStorage\offline"
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        Test-Path -LiteralPath $state | Should -BeTrue
        Test-Path -LiteralPath $offline | Should -BeTrue
    }

    It 'Allows only new Teams WebView disk-cache leaves within Packages' {
        $root = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $kept = @(
            (New-CacheFile "$root\Default\IndexedDB\state"),
            (New-CacheFile "$root\Default\CacheStorage\offline"),
            (New-CacheFile "$root\Cache\entry"),
            (New-CacheFile "$env:LOCALAPPDATA\Packages\Other_app\LocalCache\Default\Cache\entry")
        )
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        foreach ($file in $kept) { Test-Path -LiteralPath $file | Should -BeTrue; Test-SafePath $file | Should -BeFalse }
        $script:MoleCleanPathGuard = $false
        Test-SafePath "$root\Default\Cache" | Should -BeFalse
    }

    It 'Honors an explicit Packages whitelist even for Teams cache leaves' {
        $cache = New-CacheFile "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache\entry"
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value "$env:LOCALAPPDATA\Packages\*"
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Keeps caches when the owner runs or its process probe fails for <Unknown>' -ForEach @(@{Unknown=$false},@{Unknown=$true}) {
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\entry"
        if ($Unknown) { Mock Get-Process { throw 'unavailable' } }
        else { Mock Get-Process { [pscustomobject]@{ProcessName='Cursor'} } }
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Rechecks the owner after sizing in dry-run <Dry>' -ForEach @(@{Dry=$true},@{Dry=$false}) {
        Set-DryRunMode -Enabled $Dry
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\nested\entry"
        $script:CacheOwnerStarted = $false
        Mock Get-Process { if ($script:CacheOwnerStarted) { [pscustomobject]@{ProcessName='Cursor'} } }
        Mock Get-ValidatedTreeSize { $script:CacheOwnerStarted = $true; return 13 }
        Clear-AppCaches
        Should -Invoke Get-ValidatedTreeSize -Times 1 -Exactly
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
        Test-Path -LiteralPath $script:ExportListFile | Should -BeFalse
    }

    It 'Preserves protected stores even when passed to the shared sink directly' {
        $files = @(
            (New-CacheFile "$env:LOCALAPPDATA\pypoetry\Cache\virtualenvs\project\python.exe"),
            (New-CacheFile "$env:APPDATA\Slack\Service Worker\CacheStorage\offline")
        )
        $ordinary = New-CacheFile "$env:APPDATA\Slack\Cache\entry"
        Remove-SafeItems -Paths ($files + @($ordinary))
        foreach ($file in $files) { Test-Path -LiteralPath $file | Should -BeTrue }
        Test-Path -LiteralPath $ordinary | Should -BeFalse
    }

    It 'Records a last-moment busy owner as skipped with no reclaimed files' {
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\nested\entry"
        $script:OwnerProbeCalls = 0
        Mock Get-Process {
            $script:OwnerProbeCalls++
            if ($script:OwnerProbeCalls -ge 3) { [pscustomobject]@{ProcessName='Cursor'} }
        }
        Mock Write-MoleOperation {}
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
        Should -Invoke Write-MoleOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'SKIPPED' }
        Should -Invoke Write-MoleOperation -Times 0 -Exactly -ParameterFilter { $Action -eq 'REMOVED' -or $Action -eq 'FAILED' }
    }

    It 'Supports Opera root and profile caches in both app-data locations' {
        $files = @(foreach ($root in @($env:APPDATA,$env:LOCALAPPDATA)) {
            New-CacheFile "$root\Opera Software\Opera Stable\Cache\entry"
            New-CacheFile "$root\Opera Software\Opera Stable\Default\Code Cache\entry"
        })
        Clear-BrowserCaches
        foreach ($file in $files) { Test-Path -LiteralPath $file | Should -BeFalse }
    }

    It 'Keeps locked new Teams caches and cleans them after the lock closes' {
        $root = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $lock = New-CacheFile "$root\lockfile"
        $handle = [IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Clear-AppCaches; Test-Path -LiteralPath $cache | Should -BeTrue }
        finally { $handle.Dispose() }
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        Test-Path -LiteralPath $lock | Should -BeTrue
    }

    It 'Never follows a linked browser profile and still cleans a real profile' {
        $root = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $outside = New-CacheFile "$env:USERPROFILE\outside\Cache\kept"
        $link = Join-Path $root 'Profile 2'
        New-Item -ItemType Junction -Path $link -Target (Join-Path $env:USERPROFILE 'outside') | Out-Null
        try {
            Clear-BrowserCaches
            Test-Path -LiteralPath $outside | Should -BeTrue
            Test-Path -LiteralPath $cache | Should -BeFalse
        }
        finally { [IO.Directory]::Delete($link,$false) }
    }

    It 'Discards all discovered profiles when one profile is unreadable' {
        $root = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $unreadable = New-CacheFile "$root\Profile 2\Cache\entry"
        $other = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache\entry"
        $script:RealCacheGetItem = Get-Command Get-Item -CommandType Cmdlet
        Mock Get-Item { & $script:RealCacheGetItem -LiteralPath $LiteralPath -Force -ErrorAction Stop }
        Mock Get-Item { throw 'access denied' } -ParameterFilter { $LiteralPath -like '*\Google\Chrome\User Data\Profile 2' }
        Clear-BrowserCaches
        Should -Invoke Get-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*\Google\Chrome\User Data\Profile 2' }
        Test-Path -LiteralPath $cache | Should -BeTrue
        Test-Path -LiteralPath $unreadable | Should -BeTrue
        Test-Path -LiteralPath $other | Should -BeFalse
    }

    It 'Discards an oversized profile enumeration instead of cleaning a partial list' {
        $root = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        foreach ($n in 1..128) { New-Item -ItemType Directory -Path "$root\Profile $n" | Out-Null }
        Clear-BrowserCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Preserves all files in dry-run and lists only disposable cache paths' {
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\entry"
        $offline = New-CacheFile "$env:APPDATA\Cursor\Service Worker\CacheStorage\offline"
        Set-DryRunMode -Enabled $true
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        Test-Path -LiteralPath $offline | Should -BeTrue
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Match ([regex]::Escape($cache))
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match 'CacheStorage'
        (Get-CleanupStats).FilesCleaned | Should -Be 1
    }
}

Describe 'Native cache-owner process evidence' {
    It 'Detects the current process and accepts a nonexistent owner without mocks' {
        $current = Get-Process -Id $PID
        Test-MoleCacheOwnerIdle -Names @($current.ProcessName) | Should -BeFalse
        Test-MoleCacheOwnerIdle -Names @('mole-fixture-' + [guid]::NewGuid().ToString('N')) | Should -BeTrue
    }
}

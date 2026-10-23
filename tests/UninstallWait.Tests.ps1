# Real Windows process-tree tests. Never launch a vendor uninstaller.
BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\uninstall.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-MoleUninstallProcess'
    }, $true)
    if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
    else {
        # Execute exactly the previous wait for old-source red runs. Fixture
        # processes exit naturally after 15 seconds, so even this run is bounded.
        function Invoke-MoleUninstallProcess {
            param($FilePath, $ArgumentList, $TimeoutMilliseconds)
            Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
        }
    }
    $script:Shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function New-WaitFixture {
        param([switch]$ExitParent)
        $script:IdentityFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        $childCode = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 15'))
        $code = @'
$child = Start-Process -FilePath '__SHELL__' -ArgumentList '-NoProfile -NonInteractive -EncodedCommand __CHILD__' -PassThru
$self = [Diagnostics.Process]::GetCurrentProcess()
@(@{ Id = $self.Id; Created = $self.StartTime.ToUniversalTime().Ticks }, @{ Id = $child.Id; Created = $child.StartTime.ToUniversalTime().Ticks }) | ConvertTo-Json | Set-Content -LiteralPath '__FILE__'
__WAIT__
'@
        $wait = if ($ExitParent) { '' } else { 'Start-Sleep -Seconds 15' }
        $code = $code.Replace('__SHELL__', $script:Shell.Replace("'", "''")).Replace('__CHILD__', $childCode)
        $code = $code.Replace('__FILE__', $script:IdentityFile.Replace("'", "''")).Replace('__WAIT__', $wait)
        return '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    }
    function Get-FixtureProcess {
        param($Identity)
        try {
            $process = Get-Process -Id $Identity.Id -ErrorAction Stop
            if ($process.StartTime.ToUniversalTime().Ticks -eq [long]$Identity.Created) { return $process }
            $process.Dispose()
        } catch { }
        return $null
    }
}

Describe 'Bounded vendor uninstaller wait' {
    AfterEach {
        # Kill only test-owned identities, never a reused PID or an external app.
        if ($script:IdentityFile -and (Test-Path -LiteralPath $script:IdentityFile)) {
            $identities = Get-Content -LiteralPath $script:IdentityFile -Raw | ConvertFrom-Json
            foreach ($identity in $identities) {
                $process = Get-FixtureProcess $identity
                if ($process) { try { $process.Kill(); $process.WaitForExit(5000) | Out-Null } finally { $process.Dispose() } }
            }
        }
    }
    It 'Times out without killing the vendor parent or child' {
        $arguments = New-WaitFixture
        $clock = [Diagnostics.Stopwatch]::StartNew()
        { Invoke-MoleUninstallProcess -FilePath $script:Shell -ArgumentList $arguments -TimeoutMilliseconds 5000 } | Should -Throw '*timed out*'
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
        Test-Path -LiteralPath $script:IdentityFile | Should -BeTrue
        $identities = Get-Content -LiteralPath $script:IdentityFile -Raw | ConvertFrom-Json
        $identities.Count | Should -Be 2
        foreach ($identity in $identities) {
            $process = Get-FixtureProcess $identity
            $process | Should -Not -BeNullOrEmpty
            if ($process) { $process.Dispose() }
        }
    }
    It 'Keeps waiting for a child after the parent exits' {
        $arguments = New-WaitFixture -ExitParent
        { Invoke-MoleUninstallProcess -FilePath $script:Shell -ArgumentList $arguments -TimeoutMilliseconds 5000 } | Should -Throw '*timed out*'
        $identities = Get-Content -LiteralPath $script:IdentityFile -Raw | ConvertFrom-Json
        $process = Get-FixtureProcess $identities[1]
        $process | Should -Not -BeNullOrEmpty
        if ($process) { $process.Dispose() }
    }
    It 'Cancels the waiting pipeline without killing fixture processes' {
        $arguments = New-WaitFixture
        $outer = [powershell]::Create()
        $waitDefinition = (Get-Item function:Invoke-MoleUninstallProcess).ScriptBlock.ToString()
        $null = $outer.AddScript('param($definition, $exe, $arguments); Set-Item function:Invoke-MoleUninstallProcess ([scriptblock]::Create($definition)); Invoke-MoleUninstallProcess -FilePath $exe -ArgumentList $arguments')
        $null = $outer.AddArgument($waitDefinition).AddArgument($script:Shell).AddArgument($arguments)
        try {
            $pending = $outer.BeginInvoke()
            $ready = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $script:IdentityFile) -and $ready.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
            Test-Path -LiteralPath $script:IdentityFile | Should -BeTrue
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $outer.Stop()
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            $identities = Get-Content -LiteralPath $script:IdentityFile -Raw | ConvertFrom-Json
            foreach ($identity in $identities) {
                $process = Get-FixtureProcess $identity
                $process | Should -Not -BeNullOrEmpty
                if ($process) { $process.Dispose() }
            }
        }
        finally { $outer.Stop(); $outer.Dispose() }
    }
    It 'Returns the real exit code after normal completion' {
        $script:IdentityFile = $null
        $result = Invoke-MoleUninstallProcess -FilePath $script:Shell -ArgumentList '-NoProfile -NonInteractive -Command "exit 7"' -TimeoutMilliseconds 10000
        $result.ExitCode | Should -Be 7
    }
}

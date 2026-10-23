BeforeAll {
    . "$PSScriptRoot\..\lib\core\ui.ps1"
    if (-not (Get-Command Test-MoleInteractiveOutput -ErrorAction SilentlyContinue)) {
        function Test-MoleInteractiveOutput { $false }
    }
}

Describe 'Terminal presentation' {
    BeforeEach {
        Mock Write-Host {}
        Mock Test-MoleInteractiveOutput { $false }
    }

    It 'accepts the native progress parameter contract used by both scanners' {
        Mock Update-Spinner {}
        Mock Stop-Spinner {}
        Write-Progress -Activity 'Scanning apps' -Status 'Registry' -PercentComplete 50
        Should -Invoke Update-Spinner -Times 1 -Exactly -ParameterFilter { $Message -eq 'Scanning apps, Registry' }
        Write-Progress -Activity 'Scanning apps' -Completed
        Should -Invoke Stop-Spinner -Times 1 -Exactly
    }

    It 'does not emit animation or cursor escapes to redirected output' {
        Start-Spinner 'Scanning'
        Update-Spinner 'Measuring'
        Stop-Spinner
        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'uses the Mac summary frame and keeps a narrow terminal within its width' {
        Mock Get-TerminalSize { @{ Width = 40; Height = 24 } }
        Show-SummaryBlock -Heading 'Cleanup complete' -Details @('Space freed: 128 MB')
        Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter { $Object -eq ('=' * 40) }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -match 'Space freed: 128 MB' }
    }

    It 'leaves a blank line between the closing divider and the shell prompt' {
        $script:HostLines = New-Object System.Collections.Generic.List[string]
        Mock Write-Host { $script:HostLines.Add([string]$Object) }
        Mock Get-TerminalSize { @{ Width = 40; Height = 24 } }
        Show-SummaryBlock -Heading 'Cleanup complete' -Details @('Space freed: 128 MB')
        $script:HostLines[$script:HostLines.Count - 2] | Should -Be ('=' * 40)
        $script:HostLines[$script:HostLines.Count - 1] | Should -Be ''
    }

    It 'caps the summary divider at the Mac width' {
        Mock Get-TerminalSize { @{ Width = 120; Height = 24 } }
        Show-SummaryBlock -Heading 'Preview' -Details @()
        Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter { $Object -eq ('=' * 70) }
    }

    It 'stops loading before printing a result and resumes only an active section' {
        Mock Stop-Spinner {}
        Mock Start-Spinner {}
        $script:CurrentSection.Active = $true
        Write-Success 'Cache cleaned'
        Should -Invoke Stop-Spinner -Times 1 -Exactly
        Should -Invoke Start-Spinner -Times 1 -Exactly
        $script:CurrentSection.Active = $false
    }
}

Describe 'Background loading lifecycle' {
    It 'fits loading labels to terminal cells, not UTF-16 length' {
        Initialize-MoleSpinner
        $cjk = [string]([char]0x4E2D) + [char]0x6587
        [Mole.TerminalSpinner]::Fit("$cjk" + 'abc', 5) | Should -BeExactly ("$cjk" + 'a')
        [Mole.TerminalSpinner]::Fit("$cjk", 3) | Should -BeExactly ([string]([char]0x4E2D))
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        [Mole.TerminalSpinner]::Fit("a$emoji" + 'b', 2) | Should -BeExactly 'a'
        [Mole.TerminalSpinner]::Fit('plain', 80) | Should -BeExactly 'plain'
    }

    It 'writes Unicode frames directly to a console buffer regardless of its legacy code page' {
        Initialize-MoleSpinner
        if (-not ('Mole.SpinnerConsoleFixture' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace Mole {
    public static class SpinnerConsoleFixture {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr CreateConsoleScreenBuffer(uint access, uint share, IntPtr security, uint flags, IntPtr data);
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetStdHandle(int name);
        [DllImport("kernel32.dll")]
        public static extern bool SetStdHandle(int name, IntPtr handle);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
        public static extern bool ReadConsoleOutputCharacterW(IntPtr handle, StringBuilder text, uint length, uint position, out uint read);
        [DllImport("kernel32.dll")]
        public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")]
        public static extern bool AllocConsole();
        [DllImport("kernel32.dll")]
        public static extern bool FreeConsole();
    }
}
'@
        }
        $original = [Mole.SpinnerConsoleFixture]::GetStdHandle(-11)
        $buffer = [Mole.SpinnerConsoleFixture]::CreateConsoleScreenBuffer(3221225472, 3, [IntPtr]::Zero, 1, [IntPtr]::Zero)
        $ownedConsole = $false
        try {
            if ($buffer -eq [IntPtr](-1)) {
                # Headless CI may have no console. Own and release only this fixture's console.
                $ownedConsole = [Mole.SpinnerConsoleFixture]::AllocConsole()
                $ownedConsole | Should -BeTrue
                $buffer = [Mole.SpinnerConsoleFixture]::CreateConsoleScreenBuffer(3221225472, 3, [IntPtr]::Zero, 1, [IntPtr]::Zero)
            }
            $buffer | Should -Not -Be ([IntPtr](-1))
            [Mole.SpinnerConsoleFixture]::SetStdHandle(-11, $buffer) | Should -BeTrue
            [Mole.TerminalSpinner]::Start('Scanning')
            Start-Sleep -Milliseconds 250
            $text = New-Object System.Text.StringBuilder 256
            [uint32]$read = 0
            [Mole.SpinnerConsoleFixture]::ReadConsoleOutputCharacterW($buffer, $text, 256, 0, [ref]$read) | Should -BeTrue
            $text.ToString() | Should -Match ('[' + [char]0x2816 + [char]0x2832 + [char]0x2834 + [char]0x2826 + ']')
            $text.ToString() | Should -Match 'Scanning'
        }
        finally {
            [Mole.TerminalSpinner]::Stop()
            if ($buffer -ne [IntPtr](-1)) { [void][Mole.SpinnerConsoleFixture]::CloseHandle($buffer) }
            if ($ownedConsole) { [void][Mole.SpinnerConsoleFixture]::FreeConsole() }
            [void][Mole.SpinnerConsoleFixture]::SetStdHandle(-11, $original)
        }
    }

    It 'animates while the calling thread waits and stops before returning' {
        Initialize-MoleSpinner
        $original = [Console]::Out
        $capture = New-Object System.IO.StringWriter
        try {
            [Console]::SetOut($capture)
            [Mole.TerminalSpinner]::Start('Scanning')
            Start-Sleep -Milliseconds 350
            [Mole.TerminalSpinner]::Stop()
            $finished = $capture.ToString()
            $finished | Should -Match ([string][char]0x2816)
            $finished | Should -Match ([string][char]0x2832)
            Start-Sleep -Milliseconds 180
            $capture.ToString() | Should -BeExactly $finished
        }
        finally {
            [Mole.TerminalSpinner]::Stop()
            [Console]::SetOut($original)
            $capture.Dispose()
        }
    }
}

Describe 'Display-cell list columns' {
    It 'aligns ASCII, Chinese, mixed and truncated names at one right edge' {
        Mock Get-TerminalSize { @{ Width = 60; Height = 24 } }
        foreach ($name in @('Clash Party', '微信输入法', 'UU远程', ('中文应用' * 20), 'éditor')) {
            $row = Format-SizeListEntry -Name $name -Size '443.4MB'
            (Get-TerminalTextWidth $row) | Should -Be 53
            $row.EndsWith('443.4MB') | Should -BeTrue
        }
        (Format-SizeListEntry -Name ('中文应用' * 20) -Size '1MB') | Should -Match '\.\.\.'
    }

    It 'fits both list callers in a narrow terminal including a suffix' {
        Mock Get-TerminalSize { @{ Width = 40; Height = 24 } }
        $row = Format-SizeListEntry -Name ('中文项目' * 20) -Size '12MB' -Suffix ' (3 items)' -NameWidth 32
        (Get-TerminalTextWidth $row) | Should -Be 33
    }

    It 'keeps the end of a long path visible when asked' {
        Mock Get-TerminalSize { @{ Width = 60; Height = 24 } }
        $row = Format-SizeListEntry -Name '~\Projects\client-work\storefront-redesign\frontend' -Size '1.2GB' -NameWidth 30 -KeepEnd
        (Get-TerminalTextWidth $row) | Should -Be 41
        $row | Should -Match '^\.\.\..*\\frontend +1\.2GB$'
        (Format-SizeListEntry -Name '~\shop\frontend' -Size '1MB' -NameWidth 30 -KeepEnd) | Should -Match '^~\\shop\\frontend +1MB$'
    }

    It 'settles interactive results once without delaying redirected output' {
        Mock Write-Host {}
        Mock Stop-Spinner {}
        Mock Start-Sleep {}
        Mock Test-MoleInteractiveOutput { $false }
        Show-SummaryBlock -Heading 'Done'
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Mock Test-MoleInteractiveOutput { $true }
        Show-SummaryBlock -Heading 'Done'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 180 }
    }
}

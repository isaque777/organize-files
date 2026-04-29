# PowerShell argument completion for organize-files.ps1
# Source this file in your PowerShell profile to enable autocomplete

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$organizePsPath = Join-Path $scriptPath "organize-files.ps1"

# Register completer for category flags
$categoryCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)

    $categories = @(
        '-Images',
        '-Image',
        '-Videos',
        '-Video',
        '-Audio',
        '-Documents',
        '-Document',
        '-Archives',
        '-Archive',
        '-Code',
        '-Fonts',
        '-Font',
        '-Ebooks',
        '-Ebook',
        '-Subtitles',
        '-Subtitle',
        '-Data',
        '-DiskImages',
        '-DiskImage',
        '-Executables',
        '-Executable',
        '-DesignFiles',
        '-Design',
        '-Models3D',
        '-Model3D'
    )

    $categories | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

# Register completer for switch flags
$switchCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)

    $switches = @(
        '-DryRun',
        '-UseName',
        '-UseDate',
        '-UseSize',
        '-IgnoreDuplicateSuffix',
        '-OrganizeByDate',
        '-SeparateByType',
        '-SeparateMedia',
        '-UseFileNameDate',
        '-UseMetadataDate',
        '-UseSupplementalMetadata',
        '-MoveFiles',
        '-GenerateReport'
    )

    $switches | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

# Register completer for parameter options that accept values
$valueParameterCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)

    $valueParams = @(
        '-Output',
        '-LogFile',
        '-ReportFile',
        '-MaxFiles',
        '-Threads',
        '-IgnoreExtensions'
    )

    $valueParams | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

# Register completers
Register-ArgumentCompleter -CommandName $organizePsPath -ParameterName Sources -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    Get-ChildItem -Path $wordToComplete -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_.FullName, $_.Name, 'ParameterValue', $_.FullName)
    }
}

Register-ArgumentCompleter -CommandName $organizePsPath -ParameterName Targets -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    Get-ChildItem -Path $wordToComplete -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_.FullName, $_.Name, 'ParameterValue', $_.FullName)
    }
}

Register-ArgumentCompleter -CommandName $organizePsPath -ParameterName Output -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    Get-ChildItem -Path $wordToComplete -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_.FullName, $_.Name, 'ParameterValue', $_.FullName)
    }
}

Write-Host "organize-files.ps1 autocomplete loaded successfully." -ForegroundColor Green

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [Alias("Source")]
    [string[]]$Sources,

    [Parameter(Mandatory=$true)]
    [string[]]$Targets,

    [Parameter(Mandatory=$true)]
    [string]$Output,

    [switch]$DryRun,
    [string]$LogFile = "",

    [switch]$UseName,
    [switch]$UseDate,
    [switch]$UseSize,

    [switch]$IgnoreDuplicateSuffix,
    [switch]$OrganizeByDate,
    [Alias("SeparateMedia")]
    [switch]$SeparateByType,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxFiles = 0,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$Threads = 1,

    [switch]$UseFileNameDate,
    [switch]$UseMetadataDate,
    [switch]$UseSupplementalMetadata,
    [switch]$MoveFiles,
    [string[]]$IgnoreExtensions = @(),

    [Alias("Image")]
    [switch]$Images,
    [Alias("Video")]
    [switch]$Videos,
    [switch]$Audio,
    [Alias("Document")]
    [switch]$Documents,
    [Alias("Archive")]
    [switch]$Archives,
    [switch]$Code,
    [Alias("Font")]
    [switch]$Fonts,
    [Alias("Ebook")]
    [switch]$Ebooks,
    [Alias("Subtitle")]
    [switch]$Subtitles,
    [switch]$Data,
    [Alias("DiskImage")]
    [switch]$DiskImages,
    [Alias("Executable")]
    [switch]$Executables,
    [Alias("Design")]
    [switch]$DesignFiles,
    [Alias("Model3D")]
    [switch]$Models3D
)

# ================================
# DEFAULTS
# ================================
if (-not ($UseName -or $UseDate -or $UseSize)) {
    Write-Output "Defaulting to: Name + Date"
    $UseName = $true
    $UseDate = $true
}

if ($Threads -lt 1) {
    throw "-Threads must be at least 1"
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Get-CategoryDefinitions {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Category definitions file not found: $Path"
    }

    $definitions = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
            continue
        }

        $parts = $line -split "`t", 3
        if ($parts.Count -ne 3) {
            throw "Invalid category definition line: $line"
        }

        $extensions = @()
        foreach ($extension in ($parts[2] -split ' ')) {
            if (-not [string]::IsNullOrWhiteSpace($extension)) {
                $extensions += $extension.Trim()
            }
        }

        $key = $parts[0].Trim()
        $folder = $parts[1].Trim()
        if (-not $key -or -not $folder -or $extensions.Count -eq 0) {
            throw "Invalid category definition line: $line"
        }

        $definitions[$key] = @{
            Folder = $folder
            Extensions = $extensions
        }
    }

    return ,$definitions
}

$categoryDefinitions = Get-CategoryDefinitions -Path (Join-Path $scriptRoot "category-definitions.tsv")

function Get-FileNameDateFormats {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Filename date formats file not found: $Path"
    }

    $formats = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $format = $line.Trim()
        if (-not $format -or $format.StartsWith("#")) {
            continue
        }

        $formats += $format
    }

    if ($formats.Count -eq 0) {
        throw "Filename date formats file is empty: $Path"
    }

    return ,$formats
}

function Convert-DateFormatToPattern {
    param([Parameter(Mandatory=$true)][string]$Format)

    $pattern = [regex]::Escape($Format)
    $pattern = $pattern.Replace("YYYY", "(20\d{2})")
    $pattern = $pattern.Replace("MM", "([0-1]\d)")
    $pattern = $pattern.Replace("DD", "([0-3]\d)")
    return "\b{0}\b" -f $pattern
}

$fileNameDatePatterns = foreach ($format in (Get-FileNameDateFormats -Path (Join-Path $scriptRoot "filename-date-formats.txt"))) {
    Convert-DateFormatToPattern -Format $format
}

function Normalize-Extension {
    param([string]$Extension)

    if ([string]::IsNullOrWhiteSpace($Extension)) {
        return ""
    }

    $normalizedExtension = $Extension.Trim().ToLower()
    if (-not $normalizedExtension.StartsWith(".")) {
        $normalizedExtension = ".{0}" -f $normalizedExtension
    }

    return $normalizedExtension
}

$extensionToCategory = @{}
foreach ($categoryName in $categoryDefinitions.Keys) {
    $normalizedExtensions = @()

    foreach ($extension in $categoryDefinitions[$categoryName].Extensions) {
        $normalizedExtension = Normalize-Extension $extension
        if (-not $normalizedExtension) {
            continue
        }

        $normalizedExtensions += $normalizedExtension

        if (-not $extensionToCategory.ContainsKey($normalizedExtension)) {
            $extensionToCategory[$normalizedExtension] = $categoryName
        }
    }

    $categoryDefinitions[$categoryName].Extensions = $normalizedExtensions | Select-Object -Unique
}

$selectedCategories = @()
if ($Images) { $selectedCategories += "Images" }
if ($Videos) { $selectedCategories += "Videos" }
if ($Audio) { $selectedCategories += "Audio" }
if ($Documents) { $selectedCategories += "Documents" }
if ($Archives) { $selectedCategories += "Archives" }
if ($Code) { $selectedCategories += "Code" }
if ($Fonts) { $selectedCategories += "Fonts" }
if ($Ebooks) { $selectedCategories += "Ebooks" }
if ($Subtitles) { $selectedCategories += "Subtitles" }
if ($Data) { $selectedCategories += "Data" }
if ($DiskImages) { $selectedCategories += "DiskImages" }
if ($Executables) { $selectedCategories += "Executables" }
if ($DesignFiles) { $selectedCategories += "DesignFiles" }
if ($Models3D) { $selectedCategories += "Models3D" }

$hasCategoryFilters = $selectedCategories.Count -gt 0
$includedExtensions = @{}
if ($hasCategoryFilters) {
    foreach ($categoryName in $selectedCategories | Select-Object -Unique) {
        foreach ($extension in $categoryDefinitions[$categoryName].Extensions) {
            $includedExtensions[$extension] = $true
        }
    }
}

$ignoredExtensionsSet = @{}
foreach ($extension in $IgnoreExtensions) {
    $normalizedExtension = Normalize-Extension $extension
    if ($normalizedExtension) {
        $ignoredExtensionsSet[$normalizedExtension] = $true
    }
}

$duplicatePattern = '\(\d+\)(?=\.[^.]+$)'

function Should-SkipFile {
    param($file)

    $normalizedExtension = Normalize-Extension $file.Extension
    if ($normalizedExtension -and $ignoredExtensionsSet.ContainsKey($normalizedExtension)) {
        return $true
    }

    if ($IgnoreDuplicateSuffix -and ($file.Name -match $duplicatePattern)) {
        return $true
    }

    return $false
}

function Should-IncludeFile {
    param($file)

    if (Should-SkipFile $file) {
        return $false
    }

    if (-not $hasCategoryFilters) {
        return $true
    }

    $normalizedExtension = Normalize-Extension $file.Extension
    return $includedExtensions.ContainsKey($normalizedExtension)
}

function Get-CategoryNameForFile {
    param($file)

    $normalizedExtension = Normalize-Extension $file.Extension
    if (-not $normalizedExtension) {
        return $null
    }

    if ($extensionToCategory.ContainsKey($normalizedExtension)) {
        return $extensionToCategory[$normalizedExtension]
    }

    return $null
}

function Get-FileKey {
    param ($file)
    $parts = @()
    if ($UseName) { $parts += $file.Name.ToLower() }
    if ($UseDate) { $parts += $file.LastWriteTimeUtc.Ticks }
    return ($parts -join "|")
}

function Invoke-Transfer {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,

        [Parameter(Mandatory=$true)]
        [string]$Destination,

        [switch]$Force
    )

    $transferParams = @{
        Path = $Path
        Destination = $Destination
    }

    if ($Force) {
        $transferParams.Force = $true
    }

    if ($MoveFiles) {
        Move-Item @transferParams
    } else {
        Copy-Item @transferParams
    }
}

# ================================
# DATE FUNCTIONS
# ================================
$shell = $null
try {
    if (($PSVersionTable.PSEdition -eq "Desktop") -or ($env:OS -eq "Windows_NT")) {
        $shell = New-Object -ComObject Shell.Application
    }
} catch {}

function Get-DateTakenIndex($folder) {
    for ($i=0; $i -lt 50; $i++) {
        if ($folder.GetDetailsOf($null, $i) -match "Date taken") {
            return $i
        }
    }
    return $null
}

function Get-DateFromFileName($name) {

    foreach ($pattern in $fileNameDatePatterns) {
        if ($name -match $pattern) {
            try {
                $y = $matches[1]
                $m = $matches[2]
                $d = $matches[3]
                return Get-Date -Year $y -Month $m -Day $d
            } catch {}
        }
    }

    return $null
}

function Get-BestDate($file) {

    # 0. Supplemental metadata (highest priority when enabled)
    if ($UseSupplementalMetadata) {
        $supplementalMetadata = Get-SupplementalMetadata $file
        if ($supplementalMetadata) {
            $supplementalDate = Get-PrimaryDateFromSupplementalMetadata -Metadata $supplementalMetadata
            if ($supplementalDate) { return $supplementalDate }
        }
    }

    $categoryName = Get-CategoryNameForFile $file

    # 1. EXIF/Embedded metadata (best for photos and videos)
    if ($UseMetadataDate -and $shell -and ($categoryName -in @("Images", "Videos"))) {
        try {
            $folder = $shell.Namespace($file.Directory.FullName)
            $item   = $folder.ParseName($file.Name)

            $idx = Get-DateTakenIndex $folder
            if ($idx -ne $null) {
                $dateTaken = $folder.GetDetailsOf($item, $idx)
                if ($dateTaken) {
                    try { return [datetime]$dateTaken } catch {}
                }
            }
        } catch {}
    }

    # 2. Filename (optional)
    if ($UseFileNameDate) {
        $nameDate = Get-DateFromFileName $file.Name
        if ($nameDate) { return $nameDate }
    }

    # 3. Fallbacks
    if ($file.CreationTime) { return $file.CreationTime }
    return $file.LastWriteTime
}

# ================================
# SUPPLEMENTAL METADATA FUNCTIONS
# ================================
function Get-SupplementalMetadata {
    param($file)

    if (-not $UseSupplementalMetadata) {
        return $null
    }

    $metadataFileName = $file.Name + ".supplemental-metadata.json"
    $metadataPath = Join-Path $file.Directory.FullName $metadataFileName

    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            return $metadata
        } catch {
            Write-Output "Warning: Failed to parse metadata file: $metadataPath"
            return $null
        }
    }

    return $null
}

function Convert-ToDateTimeFromMetadataValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        return $Value
    }

    if ($Value -is [datetimeoffset]) {
        return $Value.UtcDateTime
    }

    if ($Value -is [string]) {
        $trimmed = $Value.Trim()
        if (-not $trimmed) {
            return $null
        }

        try {
            return [datetimeoffset]::Parse(
                $trimmed,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
            ).UtcDateTime
        } catch {}

        try {
            return [datetime]::Parse(
                $trimmed,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
            )
        } catch {}

        return $null
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        try {
            return [datetimeoffset]::FromUnixTimeSeconds([int64]$Value).UtcDateTime
        } catch {
            try {
                return [datetimeoffset]::FromUnixTimeMilliseconds([int64]$Value).UtcDateTime
            } catch {
                return $null
            }
        }
    }

    $timestampProperty = $Value.PSObject.Properties['timestamp']
    if ($timestampProperty -and $null -ne $timestampProperty.Value) {
        return Convert-ToDateTimeFromMetadataValue -Value $timestampProperty.Value
    }

    $formattedProperty = $Value.PSObject.Properties['formatted']
    if ($formattedProperty -and $formattedProperty.Value) {
        return Convert-ToDateTimeFromMetadataValue -Value $formattedProperty.Value
    }

    return $null
}

function Get-PrimaryDateFromSupplementalMetadata {
    param([object]$Metadata)

    if (-not $Metadata) {
        return $null
    }

    foreach ($candidateName in @(
        'CreationTime',
        'LastWriteTime',
        'creationTime',
        'lastWriteTime',
        'photoTakenTime',
        'modificationTime',
        'photoLastModifiedTime'
    )) {
        $property = $Metadata.PSObject.Properties[$candidateName]
        if (-not $property -or $null -eq $property.Value) {
            continue
        }

        $candidateDate = Convert-ToDateTimeFromMetadataValue -Value $property.Value
        if ($candidateDate) {
            return $candidateDate
        }
    }

    return $null
}

function Apply-SupplementalMetadata {
    param(
        [string]$FilePath,
        [object]$Metadata
    )

    if (-not $Metadata) {
        return
    }

    try {
        $primaryDate = Get-PrimaryDateFromSupplementalMetadata -Metadata $Metadata

        # Apply CreationTime if specified
        $creationDate = $null
        if ($Metadata.CreationTime) {
            $creationDate = Convert-ToDateTimeFromMetadataValue -Value $Metadata.CreationTime
        } elseif ($Metadata.creationTime) {
            $creationDate = Convert-ToDateTimeFromMetadataValue -Value $Metadata.creationTime
        } elseif ($primaryDate) {
            $creationDate = $primaryDate
        }

        if ($creationDate) {
            Set-ItemProperty -LiteralPath $FilePath -Name CreationTime -Value $creationDate -ErrorAction Stop
        } elseif ($Metadata.CreationTime -or $Metadata.creationTime) {
            Write-Output "Warning: Unsupported CreationTime metadata value for file: $FilePath"
        }

        # Apply LastWriteTime if specified
        $writeDate = $null
        if ($Metadata.LastWriteTime) {
            $writeDate = Convert-ToDateTimeFromMetadataValue -Value $Metadata.LastWriteTime
        } elseif ($Metadata.lastWriteTime) {
            $writeDate = Convert-ToDateTimeFromMetadataValue -Value $Metadata.lastWriteTime
        } elseif ($primaryDate) {
            $writeDate = $primaryDate
        }

        if ($writeDate) {
            Set-ItemProperty -LiteralPath $FilePath -Name LastWriteTime -Value $writeDate -ErrorAction Stop
        } elseif ($Metadata.LastWriteTime -or $Metadata.lastWriteTime) {
            Write-Output "Warning: Unsupported LastWriteTime metadata value for file: $FilePath"
        }

        # Apply custom properties (attributes, etc)
        if ($Metadata.Attributes) {
            $attrValue = [System.IO.FileAttributes]$Metadata.Attributes
            Set-ItemProperty -LiteralPath $FilePath -Name Attributes -Value $attrValue -ErrorAction Stop
        }

        Write-Output "Applied metadata to: $FilePath"
    } catch {
        Write-Output "Warning: Failed to apply metadata to file: $FilePath - $_"
    }
}

# ================================
# INDEX TARGETS
# ================================
Write-Output "Indexing targets..."

$targetIndex = @{}

foreach ($dir in $Targets) {
    Get-ChildItem $dir -Recurse -File | Where-Object {
        Should-IncludeFile $_
    } | ForEach-Object {

        $key = Get-FileKey $_

        $targetIndex[$key] = @{
            Path = $_.FullName
            Size = $_.Length
        }
    }
}

# ================================
# SCAN SOURCE
# ================================
if ($hasCategoryFilters) {
    Write-Output "Scanning selected categories: $($selectedCategories -join ', ')"
} else {
    Write-Output "Scanning all files..."
}

$files = Get-ChildItem $Sources -Recurse -File | Where-Object {
    Should-IncludeFile $_
}

if ($MaxFiles -gt 0) {
    $files = $files | Select-Object -First $MaxFiles
}

$total = $files.Count
$current = 0
$plans = New-Object System.Collections.Generic.List[object]
$plannedDestinations = @{}
$hasDestinationCollisions = $false
$transferred = 0
$replaced = 0
$skipped = 0
$transferVerb = if ($MoveFiles) { "MOVE" } else { "COPY" }
$replaceVerb = if ($MoveFiles) { "MOVE-REPLACE" } else { "REPLACE" }
$transferSummaryLabel = if ($MoveFiles) { "Moved" } else { "Copied" }

# ================================
# PROCESS
# ================================
foreach ($file in $files) {

    $current++

    Write-Progress -Activity "Syncing files" `
        -Status "$current / $total" `
        -PercentComplete (($current / $total) * 100)

    $key = Get-FileKey $file
    $bestDate = Get-BestDate $file

    # LOG DATES
    $dateLog = "DATE: $($file.Name) | Selected=$bestDate | Created=$($file.CreationTime) | Modified=$($file.LastWriteTime)"
    Write-Output $dateLog
    if ($LogFile) { Add-Content $LogFile $dateLog }

    # ROOT
    $destRoot = $Output
    $categoryName = Get-CategoryNameForFile $file

    # Separate by file type
    if ($SeparateByType) {
        if ($categoryName) {
            $destRoot = Join-Path $destRoot $categoryDefinitions[$categoryName].Folder
        } else {
            $destRoot = Join-Path $destRoot "Other"
        }
    }

    # Organize by date
    if ($OrganizeByDate) {
        $year  = $bestDate.ToString("yyyy")
        $month = $bestDate.ToString("MM")
        $destRoot = Join-Path (Join-Path $destRoot $year) $month
    }

    $destinationPath = Join-Path $destRoot $file.Name

    if ($targetIndex.ContainsKey($key)) {

        $target = $targetIndex[$key]

        if ($UseSize -and $UseName) {
            if ($file.Length -le $target.Size) {
                $skipped++
                continue
            }
        } else {
            $skipped++
            continue
        }

        $logLine = "${replaceVerb}: $($file.FullName) -> $destinationPath"

        if ($DryRun) {
            Write-Output "[SIMULATION] $logLine"
            if ($LogFile) { Add-Content -LiteralPath $LogFile $logLine }
        } else {
            if ($plannedDestinations.ContainsKey($destinationPath)) {
                $hasDestinationCollisions = $true
            } else {
                $plannedDestinations[$destinationPath] = $true
            }

            $plans.Add([pscustomobject]@{
                OperationType = 'Replace'
                SourcePath = $file.FullName
                DestinationPath = $destinationPath
                DestinationRoot = $destRoot
                Force = $true
                LogLine = $logLine
            }) | Out-Null
        }

    } else {

        $logLine = "${transferVerb}: $($file.FullName) -> $destinationPath"

        if ($DryRun) {
            Write-Output "[SIMULATION] $logLine"
            if ($LogFile) { Add-Content -LiteralPath $LogFile $logLine }
        } else {
            if ($plannedDestinations.ContainsKey($destinationPath)) {
                $hasDestinationCollisions = $true
            } else {
                $plannedDestinations[$destinationPath] = $true
            }

            $plans.Add([pscustomobject]@{
                OperationType = 'Transfer'
                SourcePath = $file.FullName
                DestinationPath = $destinationPath
                DestinationRoot = $destRoot
                Force = $false
                LogLine = $logLine
            }) | Out-Null
        }
    }
}

if (-not $DryRun -and $plans.Count -gt 0) {
    $effectiveThreads = [Math]::Min($Threads, $plans.Count)

    if ($hasDestinationCollisions -and $effectiveThreads -gt 1) {
        Write-Output "Destination collisions detected in the transfer plan. Falling back to a single-threaded transfer phase."
        $effectiveThreads = 1
    }

    if ($effectiveThreads -gt 1) {
        Write-Output "Processing $($plans.Count) file transfers with $effectiveThreads threads..."

        $transferWorker = {
            param(
                [string]$SourcePath,
                [string]$DestinationPath,
                [string]$DestinationRoot,
                [bool]$Force,
                [bool]$MoveFiles
            )

            $null = New-Item -ItemType Directory -Path $DestinationRoot -Force

            if ($MoveFiles) {
                if ($Force) {
                    Move-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
                } else {
                    Move-Item -LiteralPath $SourcePath -Destination $DestinationPath
                }
            } else {
                if ($Force) {
                    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
                } else {
                    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath
                }
            }
        }

        $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $effectiveThreads)
        $runspacePool.Open()
        $pendingTransfers = @()

        try {
            foreach ($plan in $plans) {
                $pipeline = [PowerShell]::Create()
                $pipeline.RunspacePool = $runspacePool

                $null = $pipeline.AddScript($transferWorker).
                    AddArgument($plan.SourcePath).
                    AddArgument($plan.DestinationPath).
                    AddArgument($plan.DestinationRoot).
                    AddArgument([bool]$plan.Force).
                    AddArgument([bool]$MoveFiles)

                $pendingTransfers += [pscustomobject]@{
                    Pipeline = $pipeline
                    Handle = $pipeline.BeginInvoke()
                }
            }

            foreach ($pendingTransfer in $pendingTransfers) {
                $pendingTransfer.Pipeline.EndInvoke($pendingTransfer.Handle) | Out-Null
                $pendingTransfer.Pipeline.Dispose()
            }
        } finally {
            foreach ($pendingTransfer in $pendingTransfers) {
                if ($pendingTransfer.Pipeline) {
                    $pendingTransfer.Pipeline.Dispose()
                }
            }

            $runspacePool.Close()
            $runspacePool.Dispose()
        }
    } else {
        foreach ($plan in $plans) {
            New-Item -ItemType Directory -Path $plan.DestinationRoot -Force | Out-Null
            Invoke-Transfer -Path $plan.SourcePath -Destination $plan.DestinationPath -Force:$plan.Force
        }
    }

    foreach ($plan in $plans) {
        Write-Output $plan.LogLine
        if ($LogFile) { Add-Content -LiteralPath $LogFile $plan.LogLine }

        if ($plan.OperationType -eq 'Replace') {
            $replaced++
        } else {
            $transferred++
        }

        # Apply supplemental metadata after transfer
        if ($UseSupplementalMetadata) {
            $sourceFile = Get-Item -LiteralPath $plan.SourcePath -ErrorAction SilentlyContinue
            if ($sourceFile) {
                $metadata = Get-SupplementalMetadata $sourceFile
                if ($metadata) {
                    Apply-SupplementalMetadata -FilePath $plan.DestinationPath -Metadata $metadata
                }
            }
        }
    }
}

# ================================
# SUMMARY
# ================================
Write-Output ""
Write-Output "========== SUMMARY =========="
Write-Output "Total scanned : $total"
Write-Output ("{0,-13}: {1}" -f $transferSummaryLabel, $transferred)
Write-Output "Replaced      : $replaced"
Write-Output "Skipped       : $skipped"
Write-Output "============================="

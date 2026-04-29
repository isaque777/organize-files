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
    [Alias("-GenerateReport")]
    [switch]$GenerateReport,
    [Alias("-ReportFile")]
    [string]$ReportFile = "",

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

function Write-TraceLog {
    param([Parameter(Mandatory=$true)][string]$Message)

    Write-Output $Message

    if (-not $LogFile) {
        return
    }

    try {
        $logDirectory = Split-Path -Parent $LogFile
        if ($logDirectory) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }

        Add-Content -LiteralPath $LogFile -Value $Message
    } catch {
        Write-Output "Warning: Failed to write log file: $LogFile - $_"
    }
}

function Resolve-SupportFilePath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$RelativePath,

        [Parameter(Mandatory=$true)]
        [string]$LegacyFileName
    )

    $preferredPath = Join-Path $scriptRoot $RelativePath
    if (Test-Path -LiteralPath $preferredPath) {
        return $preferredPath
    }

    return (Join-Path $scriptRoot $LegacyFileName)
}

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

$categoryDefinitions = Get-CategoryDefinitions -Path (Resolve-SupportFilePath -RelativePath "config/category-definitions.tsv" -LegacyFileName "category-definitions.tsv")

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
    $pattern = $pattern.Replace("HHMMSS", "(?<hour>[01]\d|2[0-3])(?<minute>[0-5]\d)(?<second>[0-5]\d)")
    $pattern = $pattern.Replace("YYYY", "(?<year>19\d{2}|20\d{2}|21\d{2})")
    $pattern = $pattern.Replace("MM", "(?<month>0[1-9]|1[0-2])")
    $pattern = $pattern.Replace("DD", "(?<day>0[1-9]|[12]\d|3[01])")
    $pattern = $pattern.Replace("HH", "(?<hour>[01]\d|2[0-3])")
    $pattern = $pattern.Replace("MI", "(?<minute>[0-5]\d)")
    $pattern = $pattern.Replace("SS", "(?<second>[0-5]\d)")
    return "(?<!\d){0}(?!\d)" -f $pattern
}

$fileNameDatePatterns = foreach ($format in (Get-FileNameDateFormats -Path (Resolve-SupportFilePath -RelativePath "config/filename-date-formats.txt" -LegacyFileName "filename-date-formats.txt"))) {
    [pscustomobject]@{
        Format = $format
        Pattern = Convert-DateFormatToPattern -Format $format
    }
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

function New-DateResult {
    param(
        [object]$Date = $null,
        [string]$Source = "",
        [bool]$Found = $false,
        [bool]$Reliable = $false
    )

    [pscustomobject]@{
        Date = $Date
        Source = $Source
        Found = $Found
        Reliable = $Reliable
    }
}

function Get-ShellDatePropertyIndex {
    param(
        $folder,
        [string]$CategoryName = ""
    )

    $preferredLabels = if ($CategoryName -eq "Videos") {
        @(
            'Media created',
            'Content created',
            'Date taken',
            'Date acquired',
            'Date created',
            'Created'
        )
    } else {
        @(
            'Date taken',
            'Content created',
            'Date acquired',
            'Media created',
            'Date created',
            'Created'
        )
    }

    $properties = @()
    for ($i=0; $i -lt 400; $i++) {
        [string]$rawLabel = $folder.GetDetailsOf($null, $i)
        $label = (($rawLabel -replace '\p{Cf}', '') -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($label)) {
            continue
        }

        $properties += [pscustomobject]@{ Index = $i; Label = $label }
    }

    foreach ($candidate in $preferredLabels) {
        $match = $properties | Where-Object { $_.Label -ieq $candidate } | Select-Object -First 1
        if ($match) {
            return $match
        }
    }

    foreach ($candidate in $preferredLabels) {
        $escapedCandidate = [regex]::Escape($candidate) -replace '\\ ', '\s+'
        $match = $properties | Where-Object { $_.Label -match "(?i)$escapedCandidate" } | Select-Object -First 1
        if ($match) {
            return $match
        }
    }

    return $null
}

function Get-DateTakenIndex($folder) {
    $property = Get-ShellDatePropertyIndex $folder
    if ($property) { return $property.Index }
    return $null
}

function Convert-FromShellDateValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $cleanedValue = ($Value -replace '\p{Cf}', '').Trim()
    if (-not $cleanedValue) {
        return $null
    }

    foreach ($format in @(
        'yyyy-MM-dd h:mm tt',
        'yyyy-MM-dd hh:mm tt',
        'yyyy-MM-dd H:mm',
        'yyyy-MM-dd HH:mm',
        'yyyy:MM:dd H:mm:ss',
        'yyyy:MM:dd HH:mm:ss',
        'M/d/yyyy h:mm tt',
        'M/d/yyyy hh:mm tt',
        'MM/dd/yyyy h:mm tt',
        'MM/dd/yyyy hh:mm tt',
        'd/M/yyyy H:mm',
        'dd/MM/yyyy HH:mm'
    )) {
        try {
            return [datetime]::ParseExact(
                $cleanedValue,
                $format,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
            )
        } catch {}
    }

    foreach ($culture in @(
        [System.Globalization.CultureInfo]::CurrentCulture,
        [System.Globalization.CultureInfo]::InvariantCulture
    )) {
        try {
            return [datetime]::Parse(
                $cleanedValue,
                $culture,
                [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
            )
        } catch {}
    }

    return $null
}

function Get-EmbeddedMetadataDate {
    param($file)

    $categoryName = Get-CategoryNameForFile $file
    if (-not ($UseMetadataDate -and $shell -and ($categoryName -in @("Images", "Videos")))) {
        return New-DateResult
    }

    try {
        $folder = $shell.Namespace($file.Directory.FullName)
        if ($null -eq $folder) {
            return New-DateResult
        }

        $item = $folder.ParseName($file.Name)
        if ($null -eq $item) {
            return New-DateResult
        }

        $property = Get-ShellDatePropertyIndex -folder $folder -CategoryName $categoryName
        if ($null -eq $property) {
            return New-DateResult
        }

        $dateTaken = $folder.GetDetailsOf($item, $property.Index)
        $parsedDate = Convert-FromShellDateValue -Value $dateTaken
        if ($parsedDate) {
            return New-DateResult -Date $parsedDate -Source ("Embedded:{0}" -f $property.Label) -Found $true -Reliable $true
        }

        return New-DateResult
    } catch {
        return New-DateResult
    }
}

function Get-DateFromFileName($name) {

    foreach ($datePattern in $fileNameDatePatterns) {
        if ($name -match $datePattern.Pattern) {
            try {
                $year = [int]$matches['year']
                $month = [int]$matches['month']
                $day = [int]$matches['day']
                $hour = if ($matches.ContainsKey('hour') -and $matches['hour']) { [int]$matches['hour'] } else { 0 }
                $minute = if ($matches.ContainsKey('minute') -and $matches['minute']) { [int]$matches['minute'] } else { 0 }
                $second = if ($matches.ContainsKey('second') -and $matches['second']) { [int]$matches['second'] } else { 0 }
                $date = Get-Date -Year $year -Month $month -Day $day -Hour $hour -Minute $minute -Second $second -ErrorAction Stop
                return New-DateResult -Date $date -Source ("Filename:{0}" -f $datePattern.Format) -Found $true -Reliable $true
            } catch {}
        }
    }

    return New-DateResult
}

function Get-BestDate {
    param(
        [Parameter(Mandatory=$true)]
        $File,

        [object]$SupplementalMetadata = $null,
        [object]$SupplementalPrimaryDate = $null,
        [object]$EmbeddedMetadataDate = $null
    )

    # 0. Supplemental metadata (highest priority when enabled)
    if ($UseSupplementalMetadata) {
        if ($SupplementalPrimaryDate -and $SupplementalPrimaryDate.Found) {
            return $SupplementalPrimaryDate
        }

        $metadataForDate = $SupplementalMetadata
        if (-not $PSBoundParameters.ContainsKey('SupplementalMetadata')) {
            $metadataForDate = Get-SupplementalMetadata $File
        }

        if ($metadataForDate) {
            $supplementalDate = Get-PrimaryDateResultFromSupplementalMetadata -Metadata $metadataForDate
            if ($supplementalDate.Found) { return $supplementalDate }
        }
    }

    # 1. EXIF/Embedded metadata (best for photos and videos)
    if ($EmbeddedMetadataDate -and $EmbeddedMetadataDate.Found) {
        return $EmbeddedMetadataDate
    }

    if (-not $PSBoundParameters.ContainsKey('EmbeddedMetadataDate')) {
        $EmbeddedMetadataDate = Get-EmbeddedMetadataDate $File
        if ($EmbeddedMetadataDate.Found) { return $EmbeddedMetadataDate }
    }

    # 2. Filename reliable fallback
    $nameDate = Get-DateFromFileName $File.Name
    if ($nameDate.Found) { return $nameDate }

    # 3. Fallbacks
    if ($File.CreationTime) { return New-DateResult -Date $File.CreationTime -Source "Filesystem:CreationTime" -Found $true -Reliable $false }
    return New-DateResult -Date $File.LastWriteTime -Source "Filesystem:LastWriteTime" -Found $true -Reliable $false
}

# ================================
# SUPPLEMENTAL METADATA FUNCTIONS
# ================================
function Get-SupplementalMetadata {
    param($file)

    if (-not $UseSupplementalMetadata) {
        return $null
    }

    $candidatePaths = @(
        (Join-Path $file.Directory.FullName ($file.Name + ".supplemental-metadata.json")),
        (Join-Path $file.Directory.FullName ($file.Name + ".json")),
        (Join-Path $file.Directory.FullName ($file.BaseName + ".json"))
    )

    foreach ($metadataPath in $candidatePaths) {
        if (Test-Path -LiteralPath $metadataPath) {
            try {
                $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
                return $metadata
            } catch {
                Write-Output "Warning: Failed to parse metadata file: $metadataPath"
                return $null
            }
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

        if ($trimmed -match '^\d{10,13}$') {
            try {
                if ($trimmed.Length -gt 10) {
                    return [datetimeoffset]::FromUnixTimeMilliseconds([int64]$trimmed).UtcDateTime
                }

                return [datetimeoffset]::FromUnixTimeSeconds([int64]$trimmed).UtcDateTime
            } catch {
                return $null
            }
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

    $result = Get-PrimaryDateResultFromSupplementalMetadata -Metadata $Metadata
    if ($result.Found) {
        return $result.Date
    }

    return $null
}

function Get-PrimaryDateResultFromSupplementalMetadata {
    param([object]$Metadata)

    if (-not $Metadata) {
        return New-DateResult
    }

    foreach ($candidateName in @(
        'CreationTime',
        'LastWriteTime',
        'creationTime',
        'lastWriteTime',
        'photoTakenTime',
        'modificationTime',
        'photoLastModifiedTime',
        'mediaCreateDate',
        'mediaCreated',
        'MediaCreateDate',
        'MediaCreated'
    )) {
        $property = $Metadata.PSObject.Properties[$candidateName]
        if (-not $property -or $null -eq $property.Value) {
            continue
        }

        $candidateDate = Convert-ToDateTimeFromMetadataValue -Value $property.Value
        if ($candidateDate) {
            return New-DateResult -Date $candidateDate -Source ("Supplemental:{0}" -f $candidateName) -Found $true -Reliable $true
        }
    }

    return New-DateResult
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

function Test-DateIsToday {
    param([object]$Date)

    if (-not $Date) {
        return $false
    }

    try {
        return ([datetime]$Date).Date -eq (Get-Date).Date
    } catch {
        return $false
    }
}

function Format-ReportDate {
    param([object]$Date)

    if (-not $Date) {
        return ""
    }

    try {
        return ([datetime]$Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    } catch {
        return ""
    }
}

function Get-DefaultReportFile {
    if ($ReportFile) {
        return $ReportFile
    }

    return (Join-Path $Output "organize-files-report.csv")
}

function Write-TransferReport {
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$Plans,

        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $reportDirectory = Split-Path -Parent $Path
    if ($reportDirectory) {
        Write-TraceLog "Ensuring report directory: $reportDirectory"
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    }

    Write-TraceLog "Preparing report rows for: $Path"
    $reportItems = @($Plans | ForEach-Object {
        $destinationFile = Get-Item -LiteralPath $_.DestinationPath -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Operation = $_.OperationType
            SourcePath = $_.SourcePath
            DestinationPath = $_.DestinationPath
            SizeBytes = $_.SizeBytes
            SelectedDate = Format-ReportDate $_.SelectedDate
            DateSource = $_.DateSource
            ReliableDateFound = $_.ReliableDateFound
            FileDateSet = $_.FileDateSet
            FileDateSetSource = $_.FileDateSetSource
            FinalCreationTime = if ($destinationFile) { Format-ReportDate $destinationFile.CreationTime } else { "" }
            FinalLastWriteTime = if ($destinationFile) { Format-ReportDate $destinationFile.LastWriteTime } else { "" }
            Status = $_.Status
        }
    })

    Write-TraceLog "Writing report rows: $($reportItems.Count)"

    if ($reportItems.Count -gt 0) {
        try {
            $reportItems | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-TraceLog "ERROR: Failed to write report: $Path - $_"
            throw
        }
    } else {
        $headers = @(
            'Operation',
            'SourcePath',
            'DestinationPath',
            'SizeBytes',
            'SelectedDate',
            'DateSource',
            'ReliableDateFound',
            'FileDateSet',
            'FileDateSetSource',
            'FinalCreationTime',
            'FinalLastWriteTime',
            'Status'
        )
        try {
            Set-Content -LiteralPath $Path -Value ('"{0}"' -f ($headers -join '","')) -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-TraceLog "ERROR: Failed to write empty report: $Path - $_"
            throw
        }
    }

    $reportFile = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($reportFile) {
        Write-TraceLog "Report written to: $Path"
        Write-TraceLog "Report size bytes: $($reportFile.Length)"
    } else {
        Write-TraceLog "WARNING: Report write completed but file was not found: $Path"
    }
}

$initialReportFile = Get-DefaultReportFile
Write-TraceLog "Report requested : $([bool]$GenerateReport)"
Write-TraceLog "Report file      : $initialReportFile"
if ($ReportFile) {
    Write-TraceLog "ReportFile param : $ReportFile"
} else {
    Write-TraceLog "ReportFile param : <default>"
}
if ($LogFile) {
    Write-TraceLog "Log file         : $LogFile"
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
$reportRows = New-Object System.Collections.Generic.List[object]
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
    $supplementalMetadata = if ($UseSupplementalMetadata) { Get-SupplementalMetadata $file } else { $null }
    $supplementalPrimaryDate = if ($supplementalMetadata) { Get-PrimaryDateResultFromSupplementalMetadata -Metadata $supplementalMetadata } else { New-DateResult }
    $embeddedMetadataDate = Get-EmbeddedMetadataDate $file
    $bestDateResult = Get-BestDate -File $file -SupplementalMetadata $supplementalMetadata -SupplementalPrimaryDate $supplementalPrimaryDate -EmbeddedMetadataDate $embeddedMetadataDate
    $bestDate = $bestDateResult.Date

    # LOG DATES
    $dateLog = "DATE: $($file.Name) | Selected=$bestDate | Source=$($bestDateResult.Source) | Reliable=$($bestDateResult.Reliable) | Created=$($file.CreationTime) | Modified=$($file.LastWriteTime)"
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
                $reportRows.Add([pscustomobject]@{
                    OperationType = 'Skip'
                    SourcePath = $file.FullName
                    DestinationPath = $target.Path
                    DestinationRoot = (Split-Path -Parent $target.Path)
                    Force = $false
                    LogLine = "SKIP: $($file.FullName) -> $($target.Path)"
                    SupplementalMetadata = $supplementalMetadata
                    SupplementalPrimaryDate = $supplementalPrimaryDate
                    EmbeddedMetadataDate = $embeddedMetadataDate
                    SizeBytes = $file.Length
                    SelectedDate = $bestDate
                    DateSource = $bestDateResult.Source
                    ReliableDateFound = [bool]$bestDateResult.Reliable
                    FileDateSet = $false
                    FileDateSetSource = ""
                    Status = "Skipped: Existing target is same size or larger"
                }) | Out-Null
                continue
            }
        } else {
            $skipped++
            $reportRows.Add([pscustomobject]@{
                OperationType = 'Skip'
                SourcePath = $file.FullName
                DestinationPath = $target.Path
                DestinationRoot = (Split-Path -Parent $target.Path)
                Force = $false
                LogLine = "SKIP: $($file.FullName) -> $($target.Path)"
                SupplementalMetadata = $supplementalMetadata
                SupplementalPrimaryDate = $supplementalPrimaryDate
                EmbeddedMetadataDate = $embeddedMetadataDate
                SizeBytes = $file.Length
                SelectedDate = $bestDate
                DateSource = $bestDateResult.Source
                ReliableDateFound = [bool]$bestDateResult.Reliable
                FileDateSet = $false
                FileDateSetSource = ""
                Status = "Skipped: Duplicate target"
            }) | Out-Null
            continue
        }

        $logLine = "${replaceVerb}: $($file.FullName) -> $destinationPath"

        if ($DryRun) {
            Write-Output "[SIMULATION] $logLine"
            if ($LogFile) { Add-Content -LiteralPath $LogFile $logLine }
        }

        if (-not $DryRun) {
            if ($plannedDestinations.ContainsKey($destinationPath)) {
                $hasDestinationCollisions = $true
            } else {
                $plannedDestinations[$destinationPath] = $true
            }
        }

        $plan = [pscustomobject]@{
            OperationType = 'Replace'
            SourcePath = $file.FullName
            DestinationPath = $destinationPath
            DestinationRoot = $destRoot
            Force = $true
            LogLine = $logLine
            SupplementalMetadata = $supplementalMetadata
            SupplementalPrimaryDate = $supplementalPrimaryDate
            EmbeddedMetadataDate = $embeddedMetadataDate
            SizeBytes = $file.Length
            SelectedDate = $bestDate
            DateSource = $bestDateResult.Source
            ReliableDateFound = [bool]$bestDateResult.Reliable
            FileDateSet = $false
            FileDateSetSource = ""
            Status = if ($DryRun) { "Planned" } else { "Pending" }
        }

        $plans.Add($plan) | Out-Null
        $reportRows.Add($plan) | Out-Null

    } else {

        $logLine = "${transferVerb}: $($file.FullName) -> $destinationPath"

        if ($DryRun) {
            Write-Output "[SIMULATION] $logLine"
            if ($LogFile) { Add-Content -LiteralPath $LogFile $logLine }
        }

        if (-not $DryRun) {
            if ($plannedDestinations.ContainsKey($destinationPath)) {
                $hasDestinationCollisions = $true
            } else {
                $plannedDestinations[$destinationPath] = $true
            }
        }

        $plan = [pscustomobject]@{
            OperationType = 'Transfer'
            SourcePath = $file.FullName
            DestinationPath = $destinationPath
            DestinationRoot = $destRoot
            Force = $false
            LogLine = $logLine
            SupplementalMetadata = $supplementalMetadata
            SupplementalPrimaryDate = $supplementalPrimaryDate
            EmbeddedMetadataDate = $embeddedMetadataDate
            SizeBytes = $file.Length
            SelectedDate = $bestDate
            DateSource = $bestDateResult.Source
            ReliableDateFound = [bool]$bestDateResult.Reliable
            FileDateSet = $false
            FileDateSetSource = ""
            Status = if ($DryRun) { "Planned" } else { "Pending" }
        }

        $plans.Add($plan) | Out-Null
        $reportRows.Add($plan) | Out-Null
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

        $plan.Status = "Completed"

        # Apply supplemental metadata after transfer
        if ($UseSupplementalMetadata -and $plan.SupplementalMetadata) {
            Apply-SupplementalMetadata -FilePath $plan.DestinationPath -Metadata $plan.SupplementalMetadata
            if ($plan.SupplementalPrimaryDate -and $plan.SupplementalPrimaryDate.Found) {
                $plan.FileDateSet = $true
                $plan.FileDateSetSource = $plan.SupplementalPrimaryDate.Source
            }
        }

        if ($UseMetadataDate -and $plan.EmbeddedMetadataDate -and $plan.EmbeddedMetadataDate.Found) {
            $destinationFile = Get-Item -LiteralPath $plan.DestinationPath -ErrorAction SilentlyContinue
            if ($destinationFile) {
                $destinationDateIsToday = (Test-DateIsToday -Date $destinationFile.CreationTime) -or (Test-DateIsToday -Date $destinationFile.LastWriteTime)

                if ((-not ($plan.SupplementalPrimaryDate -and $plan.SupplementalPrimaryDate.Found)) -or $destinationDateIsToday) {
                    try {
                        Set-ItemProperty -LiteralPath $plan.DestinationPath -Name CreationTime -Value $plan.EmbeddedMetadataDate.Date -ErrorAction Stop
                        Set-ItemProperty -LiteralPath $plan.DestinationPath -Name LastWriteTime -Value $plan.EmbeddedMetadataDate.Date -ErrorAction Stop
                        $plan.FileDateSet = $true
                        $plan.FileDateSetSource = $plan.EmbeddedMetadataDate.Source

                        $message = "Applied Date taken to: $($plan.DestinationPath)"
                        Write-Output $message
                        if ($LogFile) { Add-Content -LiteralPath $LogFile $message }
                    } catch {
                        Write-Output "Warning: Failed to apply Date taken to file: $($plan.DestinationPath) - $_"
                    }
                }
            }
        }

        if ((-not $plan.FileDateSet) -and $plan.ReliableDateFound -and $plan.DateSource -notlike 'Filesystem:*') {
            try {
                Set-ItemProperty -LiteralPath $plan.DestinationPath -Name CreationTime -Value $plan.SelectedDate -ErrorAction Stop
                Set-ItemProperty -LiteralPath $plan.DestinationPath -Name LastWriteTime -Value $plan.SelectedDate -ErrorAction Stop
                $plan.FileDateSet = $true
                $plan.FileDateSetSource = $plan.DateSource

                $message = "Applied selected date to: $($plan.DestinationPath)"
                Write-Output $message
                if ($LogFile) { Add-Content -LiteralPath $LogFile $message }
            } catch {
                Write-Output "Warning: Failed to apply selected date to file: $($plan.DestinationPath) - $_"
            }
        }
    }
}

if ($GenerateReport) {
    $resolvedReportFile = Get-DefaultReportFile
    Write-TraceLog "Generating report with $($reportRows.Count) rows..."
    Write-TraceLog "Report target: $resolvedReportFile"
    Write-TransferReport -Plans $reportRows.ToArray() -Path $resolvedReportFile
} else {
    Write-TraceLog "Report not generated because -GenerateReport was not set."
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

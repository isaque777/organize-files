param(
    [Parameter(Mandatory=$true)]
    [string]$Source,

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

    [int]$MaxFiles = 0,

    [switch]$UseFileNameDate,
    [switch]$SeparateMedia
)

# ================================
# DEFAULTS
# ================================
if (-not ($UseName -or $UseDate -or $UseSize)) {
    Write-Output "Defaulting to: Name + Date"
    $UseName = $true
    $UseDate = $true
}

$imageExt = @(".jpg",".jpeg",".png",".gif",".bmp",".webp")
$videoExt = @(".mp4",".mov",".avi",".mkv",".wmv")
$extensions = $imageExt + $videoExt

$duplicatePattern = '\(\d+\)(?=\.[^.]+$)'

function Should-SkipFile {
    param($file)
    if ($IgnoreDuplicateSuffix -and ($file.Name -match $duplicatePattern)) {
        return $true
    }
    return $false
}

function Get-FileKey {
    param ($file)
    $parts = @()
    if ($UseName) { $parts += $file.Name.ToLower() }
    if ($UseDate) { $parts += $file.LastWriteTimeUtc.Ticks }
    return ($parts -join "|")
}

# ================================
# DATE FUNCTIONS
# ================================
$shell = New-Object -ComObject Shell.Application

function Get-DateTakenIndex($folder) {
    for ($i=0; $i -lt 50; $i++) {
        if ($folder.GetDetailsOf($null, $i) -match "Date taken") {
            return $i
        }
    }
    return $null
}

function Get-DateFromFileName($name) {

    $patterns = @(
        '\b(20\d{2})(\d{2})(\d{2})\b',        # 20160421
        '\b(20\d{2})-(\d{2})-(\d{2})\b',      # 2016-04-21
        '\b(20\d{2})_(\d{2})_(\d{2})\b'       # 2016_04_21
    )

    foreach ($pattern in $patterns) {
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

    # 1. EXIF (best for photos)
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
# INDEX TARGETS
# ================================
Write-Output "Indexing targets..."

$targetIndex = @{}

foreach ($dir in $Targets) {
    Get-ChildItem $dir -Recurse -File | Where-Object {
        ($extensions -contains $_.Extension.ToLower()) -and
        (-not (Should-SkipFile $_))
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
Write-Output "Scanning source..."

$files = Get-ChildItem $Source -Recurse -File | Where-Object {
    ($extensions -contains $_.Extension.ToLower()) -and
    (-not (Should-SkipFile $_))
}

if ($MaxFiles -gt 0) {
    $files = $files | Select-Object -First $MaxFiles
}

$total = $files.Count
$current = 0
$copied = 0
$replaced = 0
$skipped = 0

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

    # Separate media
    if ($SeparateMedia) {
        if ($imageExt -contains $file.Extension.ToLower()) {
            $destRoot = Join-Path $destRoot "Images"
        } elseif ($videoExt -contains $file.Extension.ToLower()) {
            $destRoot = Join-Path $destRoot "Videos"
        }
    }

    # Organize by date
    if ($OrganizeByDate) {
        $year  = $bestDate.ToString("yyyy")
        $month = $bestDate.ToString("MM")
        $destRoot = Join-Path $destRoot "$year\$month"
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

        $logLine = "REPLACE: $($file.FullName) -> $destinationPath"

        if ($DryRun) {
            Write-Output "[SIMULATION] $logLine"
        } else {
            New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
            Copy-Item $file.FullName $destinationPath -Force
            Write-Output $logLine
            $replaced++
        }

    } else {

        $logLine = "COPY: $($file.FullName) -> $destinationPath"

        if ($DryRun) {
            Write-Output "[SIMULATION] $logLine"
        } else {
            New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
            Copy-Item $file.FullName $destinationPath
            Write-Output $logLine
            $copied++
        }
    }

    if ($LogFile) { Add-Content $LogFile $logLine }
}

# ================================
# SUMMARY
# ================================
Write-Output ""
Write-Output "========== SUMMARY =========="
Write-Output "Total scanned : $total"
Write-Output "Copied        : $copied"
Write-Output "Replaced      : $replaced"
Write-Output "Skipped       : $skipped"
Write-Output "============================="
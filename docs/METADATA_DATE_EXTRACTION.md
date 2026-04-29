# Metadata Date Extraction Guide

## Overview

The `-UseMetadataDate` flag enables extraction of date information from file metadata, particularly useful for photos and videos where Date taken or Media created information is embedded in the file.

When a Date taken value is available, the scripts also use it to repair the copied or moved file timestamp if supplemental metadata did not provide a usable date, or if the destination file date is still today's date after transfer.

## How It Works

### Date Priority Order

When `-UseMetadataDate` is enabled along with `-OrganizeByDate`, the script uses this priority order:

1. **Supplemental metadata JSON** when `-UseSupplementalMetadata` is enabled
2. **Embedded metadata** (EXIF Date taken, Windows Media created, video container dates)
3. **Filename date** from `../config/filename-date-formats.txt`
4. **File creation time** fallback
5. **File modification time** fallback

If `-UseSupplementalMetadata` is also enabled, supplemental JSON dates remain the top priority. Date taken is used as the fallback when that JSON has no usable date or the destination timestamp still resolves to today's date.

### Platform-Specific Behavior

#### Windows (PowerShell)

**Supported:** Yes, native support via Shell.Application COM object

**Prerequisites:** None - uses built-in Windows metadata API

**What it extracts:**
- EXIF "Date Taken" field for images
- Windows "Media created" and related media date fields for videos

The Date Taken value is applied to both `CreationTime` and `LastWriteTime` on the destination file when the fallback condition is met.

**Example:**
```powershell
.\organize-files.ps1 -Sources . -Targets . -Output organized `
  -UseMetadataDate -OrganizeByDate -SeparateByType
```

#### Linux/macOS (Bash)

**Supported:** Yes, requires `exiftool`

**Installation:**

**macOS (Homebrew):**
```bash
brew install exiftool
```

**Linux (Debian/Ubuntu):**
```bash
sudo apt-get install libimage-exiftool-perl
```

**Linux (Fedora/RHEL):**
```bash
sudo dnf install perl-Image-ExifTool
```

**What it extracts:**
- EXIF DateTimeOriginal
- EXIF CreateDate
- MediaCreateDate
- CreationDate and TrackCreateDate
- And other embedded metadata timestamps

When used as a fallback, this value is applied to the destination file modification time with `touch`.

**Example:**
```bash
./organize-files.sh -Sources . -Targets . -Output organized \
  -UseMetadataDate -OrganizeByDate -SeparateByType
```

## Usage Examples

### Example 1: Organize Photos by Actual Date Taken

```powershell
# PowerShell
.\organize-files.ps1 `
  -Sources "C:\Downloads\Photos" `
  -Targets "C:\Pictures\Organized" `
  -Output "C:\Pictures\Organized\New" `
  -UseMetadataDate `
  -OrganizeByDate `
  -Images
```

```bash
# Bash
./organize-files.sh \
  -Sources ~/Downloads/Photos \
  -Targets ~/Pictures/Organized \
  -Output ~/Pictures/Organized/New \
  -UseMetadataDate \
  -OrganizeByDate \
  -Images
```

Output structure:
```
New/
  Images/
    2026/
      04/
        photo1.jpg
        photo2.jpg
    2025/
      12/
        photo3.jpg
```

### Example 2: Combine Metadata and Filename Date Extraction

Some files might have incorrect metadata but correct dates in filenames.

```bash
./organize-files.sh \
  -Sources . \
  -Targets . \
  -Output organized \
  -UseMetadataDate \
  -UseFileNameDate \
  -OrganizeByDate \
  -Videos
```

Priority in this case:
1. EXIF metadata (if available)
2. Filename pattern (if found)
3. File creation time
4. File modification time

### Example 3: Dry Run to Inspect Dates

```bash
./organize-files.sh \
  -Sources . \
  -Targets . \
  -Output organized \
  -UseMetadataDate \
  -OrganizeByDate \
  -DryRun \
  -LogFile date-preview.log
```

Check `date-preview.log` to see what dates were extracted for each file.

## Supported File Types

### Images
- JPEG/JPG (EXIF)
- PNG (EXIF if embedded)
- HEIC/HEIF
- TIFF
- RAW formats (CR2, NEF, ARW, DNG, etc.)

### Videos
- MP4
- MOV
- MKV
- AVI
- WebM
- And many others supported by exiftool

### Notes on Other Formats
- **Documents** (PDF, Office files): Limited metadata support
- **Audio**: May contain metadata but typically less precise
- **Archives**: No date metadata extraction

## Troubleshooting

### PowerShell - No Dates Being Extracted

Check if Windows metadata is available:
```powershell
# Run this to verify the Shell.Application COM object is working
$shell = New-Object -ComObject Shell.Application
$folder = $shell.Namespace("C:\Path\To\Photos")
# If this runs without error, the API is available
```

### Bash - "exiftool not found"

Install exiftool for your operating system (see Installation section above).

Verify installation:
```bash
which exiftool
exiftool -ver
```

### No Dates Found in Metadata

Some files may not have embedded metadata:

```bash
# Check what metadata is in a file
exiftool -a -G1 photo.jpg | grep -i date
```

If no dates are found, the script will fall back to filename date or file times. Filesystem fallbacks are marked as fallback dates in reports.

## Filename Date Formats

Both entrypoints read filename patterns from `../config/filename-date-formats.txt`. Supported tokens are `YYYY`, `MM`, `DD`, and optional time tokens `HH`, `MI`, `SS`. Token order can vary, so formats such as `YYYYMMDD`, `MM-DD-YYYY`, `DD_MM_YYYY`, and `YYYYMMDD_HHMMSS` are supported when present in the config file.

## Report Generation

Use `-GenerateReport` to write a CSV report of copied/replaced files. If `-ReportFile` is omitted, the report is written to `<Output>/organize-files-report.csv`.

The report includes operation, source path, destination path, selected date, date source, whether a reliable date was found, whether the destination file date was set, final timestamps, and status.

## Performance Considerations

- **Metadata extraction adds processing time** - each file's metadata must be read
- **Windows performance**: Generally fast due to native API
- **Linux/macOS performance**: Slower with exiftool, especially for large batches
- **Recommendation**: For large operations, test with `-MaxFiles 10` first

## Combining with Other Flags

### Recommended Combinations

```bash
# Best practice for photo organization
./organize-files.sh \
  -Sources Downloads \
  -Targets Pictures \
  -Output Pictures/Organized \
  -UseMetadataDate \
  -UseFileNameDate \
  -OrganizeByDate \
  -SeparateByType \
  -Images \
  -Videos
```

### Avoid These Combinations

```bash
# Not recommended - UseSize overrides metadata dates
-UseMetadataDate -UseSize  # UseSize only used for duplicate replacement

# Not necessary - metadata extraction is automatic for images/videos
-UseMetadataDate -Images  # Works fine, just redundant specification
```

## Automation & Scripts

### PowerShell Script

```powershell
# organize-photos.ps1
param(
    [string]$SourcePath = "$env:USERPROFILE\Downloads\Photos",
    [string]$TargetPath = "$env:USERPROFILE\Pictures\Organized"
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

& "$scriptPath\organize-files.ps1" `
  -Sources $SourcePath `
  -Targets $TargetPath `
  -Output "$TargetPath\Processed" `
  -UseMetadataDate `
  -OrganizeByDate `
  -SeparateByType `
  -Images `
  -Videos `
  -LogFile "$scriptPath\organize-$(Get-Date -Format 'yyyyMMdd').log"
```

### Bash Script

```bash
#!/bin/bash
# organize-photos.sh

SOURCE_PATH="${1:-~/Downloads/Photos}"
TARGET_PATH="${2:-~/Pictures/Organized}"

./organize-files.sh \
  -Sources "$SOURCE_PATH" \
  -Targets "$TARGET_PATH" \
  -Output "$TARGET_PATH/Processed" \
  -UseMetadataDate \
  -OrganizeByDate \
  -SeparateByType \
  -Images \
  -Videos \
  -LogFile "./organize-$(date +%Y%m%d).log"
```

## See Also

- [organize-files README](../readme.md)
- [Parameter Validation & Autocomplete](VALIDATION_AND_AUTOCOMPLETE.md)
- [EXIF Specification](https://en.wikipedia.org/wiki/Exif)

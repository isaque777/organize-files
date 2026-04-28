# Supplemental Metadata Guide

## Overview

The `-UseSupplementalMetadata` flag enables the script to look for accompanying JSON files that contain custom metadata for each source file. When found, this metadata is applied to the file during the copy/move operation.

This is useful when you have:
- Files with incorrect modification dates that need correction
- Custom metadata you want to preserve with files
- Bulk operations that need precise date control
- External date information that should override file properties

## Metadata File Format

Each metadata file must be named `{filename}.supplemental-metadata.json` and be in the same directory as the source file.

### File Naming Convention

For a file named `photo.jpg`, the metadata file should be named:
```
photo.jpg.supplemental-metadata.json
```

### JSON Structure

```json
{
  "CreationTime": "2024-06-15T10:30:00Z",
  "LastWriteTime": "2024-06-15T10:30:00Z",
  "Attributes": "Normal"
}
```

### Supported Properties

| Property | Type | Description | Platform |
|----------|------|-------------|----------|
| `CreationTime` | ISO 8601 DateTime | File creation timestamp | Windows, Linux, macOS |
| `LastWriteTime` | ISO 8601 DateTime | File modification timestamp | Windows, Linux, macOS |
| `Attributes` | String | File attributes (Windows only) | Windows |

### DateTime Format

Use ISO 8601 format with UTC timezone indicator:
- `2024-06-15T10:30:00Z` - With timezone
- `2024-06-15T10:30:00` - Without timezone (interpreted as local)
- `2024-06-15` - Date only (time defaults to 00:00:00)

## Usage

### Basic Example

```powershell
# PowerShell
.\organize-files.ps1 `
  -Sources "C:\source" `
  -Targets "C:\target" `
  -Output "C:\output" `
  -UseSupplementalMetadata `
  -OrganizeByDate
```

```bash
# Bash
./organize-files.sh \
  -Sources ./source \
  -Targets ./target \
  -Output ./output \
  -UseSupplementalMetadata \
  -OrganizeByDate
```

### Creating Metadata Files Manually

Create `myfile.jpg.supplemental-metadata.json`:

```json
{
  "LastWriteTime": "2020-07-04T14:30:00Z"
}
```

When copying `myfile.jpg` with `-UseSupplementalMetadata`, the destination file will have its modification date set to July 4, 2020 at 2:30 PM UTC.

### Bulk Metadata Generation

#### PowerShell Script to Generate Metadata

```powershell
# Generate metadata for all files in a directory
$directory = "C:\Photos"
$year = 2020
$month = 5
$day = 15

Get-ChildItem $directory -File | ForEach-Object {
    $metadata = @{
        LastWriteTime = Get-Date -Year $year -Month $month -Day $day -Hour 12 -Minute 0 -Second 0 -AsUTC | Get-Date -Format "o"
    }
    
    $metadataPath = "$($_.FullName).supplemental-metadata.json"
    $metadata | ConvertTo-Json | Set-Content -Path $metadataPath
    
    Write-Host "Created: $metadataPath"
}
```

#### Bash Script to Generate Metadata

```bash
#!/bin/bash
# Generate metadata for all files in a directory

directory="."
target_date="2020-05-15T12:00:00Z"

for file in "$directory"/*; do
    if [[ ! -f "$file" ]] || [[ "$file" == *.supplemental-metadata.json ]]; then
        continue
    fi
    
    metadata_file="${file}.supplemental-metadata.json"
    
    cat > "$metadata_file" <<EOF
{
  "LastWriteTime": "$target_date"
}
EOF
    
    echo "Created: $metadata_file"
done
```

## Workflow Examples

### Example 1: Organize Photos with Preserved Original Dates

**Scenario:** You have photos that were re-downloaded, losing their original dates. You have a separate record of when each was taken.

**Setup:**

1. Create metadata files with original dates:
```bash
$ cat > IMG_001.jpg.supplemental-metadata.json
{
  "LastWriteTime": "2019-06-15T14:30:00Z"
}
$ cat > IMG_002.jpg.supplemental-metadata.json
{
  "LastWriteTime": "2019-07-20T09:15:00Z"
}
```

2. Run the organization:
```bash
./organize-files.sh \
  -Sources ./downloaded_photos \
  -Targets ./organized_photos \
  -Output ./organized_photos/new \
  -UseSupplementalMetadata \
  -OrganizeByDate \
  -Images
```

3. Result: Photos are organized in `new/Images/2019/06/` and `new/Images/2019/07/` with correct dates.

### Example 2: Restore Metadata from External Source

**Scenario:** You have a CSV or database with filename and date information.

**Setup:**

1. Generate metadata files from CSV:
```powershell
$csv = Import-Csv "metadata.csv" # Columns: FileName, TakenDate
$sourceDir = "C:\Photos"

foreach ($row in $csv) {
    $file = Join-Path $sourceDir $row.FileName
    if (Test-Path $file) {
        $metadata = @{
            LastWriteTime = [datetime]$row.TakenDate | Get-Date -Format "o"
            CreationTime = [datetime]$row.TakenDate | Get-Date -Format "o"
        }
        $metadataFile = "$file.supplemental-metadata.json"
        $metadata | ConvertTo-Json | Set-Content $metadataFile
    }
}
```

### Example 3: Combine with Other Date Options

```bash
# Priority order: Metadata > FileName > Creation Time > Modification Time
./organize-files.sh \
  -Sources ./files \
  -Targets ./organized \
  -Output ./organized/new \
  -UseSupplementalMetadata \
  -UseFileNameDate \
  -OrganizeByDate \
  -Videos
```

With this setup:
1. If `video.mp4.supplemental-metadata.json` exists, use that date
2. Otherwise, extract from filename like `video_2020-05-15.mp4`
3. Otherwise, use file creation time
4. Otherwise, use modification time

## Combining with Other Features

### With Metadata Date Extraction

```bash
# Extract EXIF from files, but override with supplemental metadata if present
./organize-files.sh \
  -Sources ./photos \
  -Targets ./archive \
  -Output ./archive/new \
  -UseMetadataDate \
  -UseSupplementalMetadata \
  -OrganizeByDate \
  -Images
```

Priority: Supplemental > EXIF > Filename > Creation Time > Modification Time

### With Dry-Run

```bash
# Preview what dates would be applied
./organize-files.sh \
  -Sources ./files \
  -Targets ./target \
  -Output ./output \
  -UseSupplementalMetadata \
  -OrganizeByDate \
  -DryRun \
  -LogFile preview.log
```

Check `preview.log` to see what dates are being applied.

### With Multithreading

```powershell
# Metadata is applied after all files are copied with parallel threads
.\organize-files.ps1 `
  -Sources $sourceDirs `
  -Targets $targetDirs `
  -Output $outputDir `
  -UseSupplementalMetadata `
  -Threads 4
```

## Troubleshooting

### Metadata Not Being Applied

1. **Check filename pattern:** Ensure the JSON file is named exactly `{filename}.supplemental-metadata.json`
   ```
   ✓ photo.jpg.supplemental-metadata.json
   ✗ photo.supplemental-metadata.json
   ✗ photo.jpg-metadata.json
   ```

2. **Verify JSON syntax:** Use a JSON validator
   ```bash
   cat example.jpg.supplemental-metadata.json | python -m json.tool
   ```

3. **Check flag is enabled:**
   ```powershell
   # Make sure to include -UseSupplementalMetadata
   .\organize-files.ps1 -UseSupplementalMetadata ...
   ```

4. **Check file accessibility:**
   ```powershell
   Test-Path -LiteralPath "C:\file.jpg.supplemental-metadata.json"
   ```

### Invalid Date Format

**Error:** "Failed to apply metadata to file"

**Solution:** Ensure dates are valid ISO 8601 format:
```json
{
  "LastWriteTime": "2024-06-15T10:30:00Z"
}
```

Invalid formats:
```json
{
  "LastWriteTime": "June 15, 2024"
}
{
  "LastWriteTime": "2024-06-15 10:30:00"
}
{
  "LastWriteTime": "6/15/2024"
}
```

### Permission Denied

**Error:** "Permission denied" when setting file dates

**Windows:** Run PowerShell as Administrator
```powershell
Start-Process powershell -Verb RunAs
```

**Linux/macOS:** Ensure you have write permissions to destination
```bash
chmod u+w destination_directory
```

## Performance Considerations

- **Metadata lookup:** Minimal overhead - only searches for files with matching names
- **Metadata parsing:** Fast JSON parsing for each matched file
- **Date setting:** Slightly slower than copy alone due to additional property setting
- **Recommendation:** Test with `-MaxFiles 10` first to verify behavior

## See Also

- [organize-files README](readme.md)
- [Metadata Date Extraction Guide](METADATA_DATE_EXTRACTION.md)
- [ISO 8601 Date Format](https://en.wikipedia.org/wiki/ISO_8601)

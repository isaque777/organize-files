# Organize Files CLI

A flexible file-organizing CLI for syncing, deduplicating, and sorting many different file types across directories.

The CLI entrypoints are `organize-files.ps1` for PowerShell and `organize-files.sh` for Bash. Both support the same command-line flags across Windows, Linux, and macOS.

This tool is especially useful for files retrieved from Google Cloud/Google Photos exports (for example, Google Takeout), where you want to copy and merge those files into an existing local library while preserving and normalizing metadata.

---

## Features

* Multiple source directories in a single run
* Scans all files by default when no type flags are provided
* Optional category flags for images, videos, audio, documents, archives, code, fonts, ebooks, subtitles, data, disk images, executables, design files, and 3D models
* Broader extension coverage including RAW camera formats, macro-enabled Office files, Jupyter notebooks, CAD assets, virtual disk images, AppImages, and more
* Optional `-IgnoreExtensions` list to skip specific extensions
* Copy by default, or move files with `-MoveFiles`
* Optional multithreaded transfer phase with `-Threads`
* Optional type-based folder separation with `-SeparateByType`
* Optional year/month organization with `-OrganizeByDate`
* Command-line interface with matching PowerShell and Bash entrypoints
* Shared category-definition and filename-date format files consumed by both entrypoints to keep rules aligned
* Native Bash implementation for Linux and macOS, not just a PowerShell wrapper
* EXIF or shell metadata date lookup when available
* Filename date extraction fallback
* **Optional supplemental metadata from accompanying JSON files** to override or preserve file properties
* Deduplication and optional size-based replacement logic
* Dry-run mode, logging support, and max-file limits
* Backward-compatible `-SeparateMedia` alias for `-SeparateByType`

---

## Parameter Validation & Autocomplete

### PowerShell

**Parameter Validation:**
- Unknown parameters are automatically rejected with an error message
- `-MaxFiles` and `-Threads` must be positive integers
- All parameters are validated before execution

**Autocomplete Support:**

Load the completion script in your PowerShell profile:

```powershell
# Add this to your profile (usually $PROFILE)
. "C:\path\to\organize-files\organize-files.completion.ps1"
```

This enables:
- Tab completion for all available flags (`-Images`, `-Videos`, `-DryRun`, etc.)
- Directory completion for `-Sources`, `-Targets`, and `-Output` parameters
- Suggested extensions for `-IgnoreExtensions`

### Bash/Linux/macOS

**Parameter Validation:**
- Unknown arguments are rejected with an error message
- `-MaxFiles` must be a non-negative integer
- `-Threads` must be a positive integer (≥ 1)
- All parameters are validated before execution

**Autocomplete Support:**

Install the completion script:

```bash
# Add this to your .bashrc or .bash_profile
source /path/to/organize-files/organize-files.completion.sh

# Or copy to bash_completion.d
sudo cp organize-files.completion.sh /etc/bash_completion.d/organize-files
```

This enables:
- Tab completion for all available flags
- Directory completion for `-Sources`, `-Targets`, and `-Output`
- File completion for `-LogFile`
- Common extensions for `-IgnoreExtensions`

---

## Supported Categories

The script currently knows these file groups:

* `-Images`
* `-Videos`
* `-Audio`
* `-Documents`
* `-Archives`
* `-Code`
* `-Fonts`
* `-Ebooks`
* `-Subtitles`
* `-Data`
* `-DiskImages`
* `-Executables`
* `-DesignFiles`
* `-Models3D`

If you do not pass any category flags, the script scans all files instead of limiting itself to known media extensions.

---

## Output Structure

When `-SeparateByType` is enabled, files are written into category folders like these:

```text
OrganizedFiles/
  Images/
    2026/
      04/
  Audio/
    2026/
      04/
  Documents/
    2026/
      04/
  Other/
    2026/
      04/
```

Unknown extensions go into `Other` when type separation is enabled.

---

## Parameters

### Core Options

| Parameter | Type | Description |
| --------- | ---- | ----------- |
| `-Sources` | `string[]` | One or more source directories |
| `-Targets` | `string[]` | Target directories used for dedup comparison |
| `-Output` | `string` | Output directory |
| `-MoveFiles` | `switch` | Move files instead of copying them |
| `-DryRun` | `switch` | Simulate the run without copying or moving |
| `-LogFile` | `string` | Optional log file path |
| `-UseName` | `switch` | Use the filename in dedup matching |
| `-UseDate` | `switch` | Use the file timestamp in dedup matching |
| `-UseSize` | `switch` | Use file size when deciding replacements |
| `-IgnoreDuplicateSuffix` | `switch` | Ignore files like `file(1).jpg` |
| `-IgnoreExtensions` | `string[]` | Skip extensions such as `.tmp`, `bak`, or `log` |
| `-SeparateByType` | `switch` | Create category folders like `Images`, `Audio`, `Documents`, etc. |
| `-OrganizeByDate` | `switch` | Add `YYYY/MM` folders under the output path |
| `-MaxFiles` | `int` | Limit the number of processed files |
| `-Threads` | `int` | Number of worker threads used for copy or move operations |
| `-UseFileNameDate` | `switch` | Try to extract a date from filenames like `IMG_20160421.jpg` |
| `-UseMetadataDate` | `switch` | Extract date from file metadata (EXIF for images/videos, requires exiftool on Linux/macOS) |
| `-UseSupplementalMetadata` | `switch` | Apply metadata from accompanying `.supplemental-metadata.json` files (dates, attributes, etc.) |

### Category Flags

| Parameter | Description |
| --------- | ----------- |
| `-Images` | Process common image and camera raw formats |
| `-Videos` | Process common video formats |
| `-Audio` | Process music and audio formats |
| `-Documents` | Process office, text, markdown, and document files |
| `-Archives` | Process compressed archive formats |
| `-Code` | Process source code and script files |
| `-Fonts` | Process font files |
| `-Ebooks` | Process ebook and comic-book archive formats |
| `-Subtitles` | Process subtitle and caption files |
| `-Data` | Process structured data and database files |
| `-DiskImages` | Process ISO and virtual disk images |
| `-Executables` | Process installer and executable package files |
| `-DesignFiles` | Process design project files |
| `-Models3D` | Process 3D model and CAD files |

---

## Usage Examples

### Dry Run for Selected File Types

```powershell
.\organize-files.ps1 `
  -Sources "E:\cloud","F:\camera-roll" `
  -Targets "D:\Library" `
  -Output "D:\OrganizedFiles" `
  -Threads 4 `
  -Images -Videos -Audio `
  -SeparateByType `
  -OrganizeByDate `
  -UseFileNameDate `
  -DryRun
```

### Scan Everything When No Flags Are Provided

```powershell
.\organize-files.ps1 `
  -Sources "E:\mixed-backup","F:\desktop-export" `
  -Targets "D:\Library" `
  -Output "D:\OrganizedFiles" `
  -SeparateByType `
  -IgnoreExtensions ".tmp","bak","log"
```

### Move Archive Files Instead of Copying

```powershell
.\organize-files.ps1 `
  -Sources "E:\downloads" `
  -Targets "D:\Library" `
  -Output "D:\OrganizedFiles" `
  -Archives `
  -SeparateByType `
  -MoveFiles
```

### Linux or macOS Bash Script

```bash
./organize-files.sh \
  -Sources "/mnt/cloud" "/mnt/backup" \
  -Targets "/srv/library" \
  -Output "/srv/organized-files" \
  -Threads 4 \
  -Documents -Archives \
  -IgnoreExtensions ".tmp" ".bak" \
  -SeparateByType
```

The Bash script is a native implementation and does not shell out to PowerShell.

---

## How Date Detection Works

Priority order:

1. EXIF or shell metadata when available
2. Filename date extraction when `-UseFileNameDate` is enabled
3. `CreationTime`
4. `LastWriteTime`

---

## Example Log Output

```text
DATE: report.pdf | Selected=2026-04-28 | Created=2026-04-28 | Modified=2026-04-28
COPY: D:\source\report.pdf -> D:\OrganizedFiles\Documents\2026\04\report.pdf
```

---

## Known Limitations

* The Bash implementation uses optional `exiftool` metadata when it is available. Without it, Linux and macOS runs fall back to filename and filesystem timestamps.
* `-Threads` parallelizes only the copy or move phase. File discovery, date selection, and dedup decisions remain serial.
* When multiple planned transfers resolve to the same destination path, the script automatically falls back to single-threaded transfer execution to avoid races.
* Unknown extensions can still be copied when no category flags are used, but they are only grouped into a named category if the script recognizes their extension.
* Files without EXIF or filename dates fall back to filesystem dates.
* Some apps strip metadata, so timestamps may not reflect when a photo or video was originally created.

---

## Requirements

* Windows PowerShell 5+ or PowerShell 7+ for `organize-files.ps1`
* Bash 4+ for `organize-files.sh`
* Standard `find`, `stat`, `date`, `cp`, `mv`, and `xargs` utilities on Linux or macOS
* No required external dependencies

Optional:

* `exiftool` for richer media date detection in the Bash script

---

## License

MIT License


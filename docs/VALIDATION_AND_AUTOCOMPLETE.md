# Parameter Validation & Autocomplete Enhancement Summary

This document summarizes the parameter validation and autocomplete improvements added to the organize-files scripts.

## Changes Made

### 1. PowerShell Script (`organize-files.ps1`)

**Added Parameter Validation:**
- `[CmdletBinding()]` attribute: Automatically rejects unknown/invalid parameters
- `[ValidateRange()]` for numeric parameters:
  - `-MaxFiles`: Must be ≥ 0
  - `-Threads`: Must be ≥ 1 (positive integer)
- Report options:
  - `-GenerateReport`: Writes a CSV report for copied/replaced files, dry-run planned operations, or skipped duplicates
  - `-ReportFile`: Optional report path

**Benefits:**
- Unknown parameters now produce clear error messages
- Invalid values are caught before execution
- Improved robustness and user feedback

### 2. Bash Script (`organize-files.sh`)

**Added Parameter Validation Functions:**
- `validate_positive_integer()`: Validates non-negative integers (e.g., MaxFiles)
- `validate_positive_integer_nonzero()`: Validates positive integers (e.g., Threads)

**Applied to:**
- `-MaxFiles` validation
- `-Threads` validation

**Benefits:**
- Clear error messages for invalid input
- Consistent validation across all numeric parameters
- Prevents silent failures from bad input

### 3. PowerShell Completion Script (`organize-files.completion.ps1`)

**Features:**
- Registers argument completers for all parameter types
- Directory completion for `-Sources`, `-Targets`, `-Output`
- Flag completion for all switch parameters
- Value parameter completion for `-LogFile`, `-MaxFiles`, `-Threads`, etc.
- Common category and file type suggestions

**Installation:**
```powershell
. "C:\path\to\organize-files.completion.ps1"
```

### 4. Bash Completion Script (`organize-files.completion.sh`)

**Features:**
- Tab completion for all flags
- Directory completion for path parameters
- File completion for `-LogFile`
- Extension suggestions for `-IgnoreExtensions`
- Support for common file extensions (jpg, png, pdf, etc.)

**Installation:**
```bash
source /path/to/organize-files.completion.sh
# or
sudo cp organize-files.completion.sh /etc/bash_completion.d/organize-files
```

## Parameter Validation Rules

### PowerShell

| Parameter | Validation | Error if Invalid |
|-----------|-----------|-----------------|
| `-MaxFiles` | Must be ≥ 0 | "[CmdletBinding()] error" |
| `-Threads` | Must be ≥ 1 | "[CmdletBinding()] error" |
| `-ReportFile` | Optional file path | Parent directory is created when reporting runs |
| Any unknown param | Not in parameter list | "Unknown parameter" error |

### Bash

| Parameter | Validation | Error Message |
|-----------|-----------|--------------|
| `-MaxFiles` | Must be ≥ 0 | "-MaxFiles must be a non-negative integer" |
| `-Threads` | Must be ≥ 1 | "-Threads must be a positive integer" |
| `-ReportFile` | Requires a value when supplied | "Missing value for -ReportFile" |
| Any unknown flag | Falls to default case | "Unknown argument: ..." |

## Autocomplete Examples

### PowerShell
```powershell
PS> ./organize-files.ps1 -<TAB>
-Sources      -Targets      -Output       -DryRun       -UseName
-UseDate      -UseSize      -MaxFiles     -Threads      -Images
-Videos       -Audio        -Documents    ...

PS> ./organize-files.ps1 -Sources <TAB>
# Shows directories in current path
```

### Bash
```bash
$ ./organize-files.sh -<TAB>
# Shows all available flags
-Sources          -Targets          -Output           -DryRun
-UseName          -UseDate          -UseSize          -Images
-Videos           -Audio            -Documents        ...

$ ./organize-files.sh -Sources <TAB>
# Shows directories in current path
```

## Testing Parameter Validation

### PowerShell - Invalid Parameters
```powershell
# These will now fail with clear error messages:
./organize-files.ps1 -Sources . -Targets . -Output out -InvalidParam foo
# Error: Unknown parameter. This script does not contain a parameter that matches the name 'InvalidParam'.

./organize-files.ps1 -Sources . -Targets . -Output out -Threads -5
# Error: Cannot validate argument on parameter 'Threads'. The "-5" argument is less than the minimum allowed range of "1".
```

### Bash - Invalid Parameters
```bash
# These will now fail with clear error messages:
./organize-files.sh -Sources . -Targets . -Output out -InvalidFlag
# Error: Unknown argument: -InvalidFlag

./organize-files.sh -Sources . -Targets . -Output out -Threads abc
# Error: -Threads must be a positive integer, got: abc
```

## Files Added

1. **organize-files.completion.ps1** - PowerShell autocomplete script
2. **organize-files.completion.sh** - Bash autocomplete script

## Files Modified

1. **organize-files.ps1** - Added `[CmdletBinding()]` and `[ValidateRange()]` attributes
2. **organize-files.sh** - Added validation functions and validation calls
3. **readme.md** - Added documentation for validation and autocomplete features

## Usage Notes

- PowerShell: Completion requires sourcing the `.completion.ps1` script in your profile
- Bash: Completion can be sourced in `.bashrc` or installed system-wide in bash_completion.d
- Both scripts now provide immediate feedback for invalid parameters
- Autocomplete suggestions adapt based on context (e.g., directories for path parameters)

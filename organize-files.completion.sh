#!/usr/bin/env bash
# Bash completion script for organize-files.sh
# Install by adding this to your .bashrc or .bash_profile:
#   source /path/to/organize-files.completion.sh
# or copy to /etc/bash_completion.d/organize-files

_organize_files_completion() {
    local cur prev words cword
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD

    # All available options
    local opts="-Sources -Source -Targets -Output -LogFile -MaxFiles -Threads 
                -DryRun -UseName -UseDate -UseSize -IgnoreDuplicateSuffix 
                -IgnoreExtensions -OrganizeByDate -SeparateByType -SeparateMedia 
                -UseFileNameDate -UseMetadataDate -UseSupplementalMetadata -MoveFiles -GenerateReport -ReportFile -Images -Image -Videos -Video -Audio 
                -Documents -Document -Archives -Archive -Code -Fonts -Font 
                -Ebooks -Ebook -Subtitles -Subtitle -Data -DiskImages -DiskImage 
                -Executables -Executable -DesignFiles -Design -Models3D -Model3D 
                -h --help"

    # Options that require values
    case "$prev" in
        -Sources|-Source)
            COMPREPLY=( $(compgen -d -- "$cur") )
            return 0
            ;;
        -Targets)
            COMPREPLY=( $(compgen -d -- "$cur") )
            return 0
            ;;
        -Output)
            COMPREPLY=( $(compgen -d -- "$cur") )
            return 0
            ;;
        -LogFile|-ReportFile)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
            ;;
        -MaxFiles)
            # Expect integer
            return 0
            ;;
        -Threads)
            # Expect integer
            return 0
            ;;
        -IgnoreExtensions)
            # Suggest common extensions
            COMPREPLY=( $(compgen -W "jpg jpeg png gif bmp txt doc docx pdf xls xlsx zip tar gz" -- "$cur") )
            return 0
            ;;
    esac

    # Complete flag names
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    fi

    return 0
}

# Register the completion function
complete -o dirnames -F _organize_files_completion organize-files.sh

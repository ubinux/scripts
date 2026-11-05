#!/bin/bash

# Replacement pairs: OLD_STRS[i] -> NEW_STRS[i]
OLD_STRS=("flatcar_production" "flatcar_test")
NEW_STRS=("ubinux_production" "ubinux_test")

usage() {
    cat <<EOF
Usage: $(basename "$0") [ARCH] [--dry-run] [-h|--help]

Replace "flatcar_production" / "flatcar_test" with
"ubinux_production" / "ubinux_test" in the build image directory
./__build__/images/images/<ARCH>-usr/latest/,
including file names, symlinks and *.sh / *.README contents.

Arguments:
  ARCH              Target architecture directory suffix.
                    The script operates on ./__build__/images/images/<ARCH>-usr/latest/
                    (default: amd64)

Options:
  --dry-run         Preview changes without modifying any files
  -h, --help        Show this help message and exit

Examples:
  $(basename "$0")                # use default ARCH=amd64
  $(basename "$0") arm64          # operate on ./__build__/images/images/arm64-usr/latest/
  $(basename "$0") arm64 --dry-run
  $(basename "$0") --help         # show this help
EOF
}

arch="amd64"
dry_run=0
positional_args=()

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        --dry-run)
            dry_run=1
            ;;
        -*)
            echo "Error: unknown option: $arg" >&2
            usage >&2
            exit 2
            ;;
        *)
            positional_args+=("$arg")
            ;;
    esac
done

if [ "${#positional_args[@]}" -gt 1 ]; then
    echo "Error: expected at most one ARCH argument." >&2
    usage >&2
    exit 2
fi

if [ "${#positional_args[@]}" -eq 1 ]; then
    arch="${positional_args[0]}"
fi

if [[ ! "$arch" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]]; then
    echo "Error: invalid ARCH '$arch'." >&2
    exit 2
fi

if [ "${#OLD_STRS[@]}" -ne "${#NEW_STRS[@]}" ]; then
    echo "Error: OLD_STRS and NEW_STRS must contain the same number of entries." >&2
    exit 2
fi

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s/%s\n' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" "$(basename -- "${BASH_SOURCE[0]}")")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"

# Directories to scan
TARGET_DIRS=(
    "${SCRIPT_DIR}/__build__/images/images/${arch}-usr/latest/"
)

SCRIPT_NAME="$(basename "$0")"

renamed_count=0
replaced_count=0
relinked_count=0
skipped_count=0
failed_count=0

# Build an extended-regexp pattern matching any old string
# e.g. flatcar_production|flatcar_test
GREP_PATTERN=""
SED_ARGS=()
for old in "${OLD_STRS[@]}"; do
    if [ -z "$GREP_PATTERN" ]; then
        GREP_PATTERN="$old"
    else
        GREP_PATTERN="${GREP_PATTERN}|${old}"
    fi
done
for i in "${!OLD_STRS[@]}"; do
    SED_ARGS+=("-e" "s/${OLD_STRS[$i]}/${NEW_STRS[$i]}/g")
done

for dir in "${TARGET_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        echo "Warning: Directory '$dir' does not exist, skipping."
        skipped_count=$((skipped_count + 1))
        continue
    fi

    echo "=============================================="
    echo "Scanning directory: $dir"
    if [ "$dry_run" -eq 1 ]; then
        echo "Dry run: no files will be modified."
    fi

    # Build the -name expression for all OLD_STR prefixes:
    #   -name "flatcar_production*" -o -name "flatcar_test*"
    NAME_ARGS=()
    for old in "${OLD_STRS[@]}"; do
        [ ${#NAME_ARGS[@]} -gt 0 ] && NAME_ARGS+=("-o")
        NAME_ARGS+=("-name" "${old}*")
    done

    # ------------------------------------------------------------------
    # 1) Rename files (regular files AND symlinks themselves)
    # ------------------------------------------------------------------
    rename_hits=0
    while IFS= read -r -d '' file; do
        # Never rename the script itself
        if [ "$(readlink -f "$file" 2>/dev/null || echo "$file")" = "$SCRIPT_PATH" ]; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
        rename_hits=$((rename_hits + 1))

        base="$(basename "$file")"
        newbase="$base"
        for i in "${!OLD_STRS[@]}"; do
            old="${OLD_STRS[$i]}"
            new="${NEW_STRS[$i]}"
            newbase="${newbase//$old/$new}"
        done

        if [ "$newbase" != "$base" ]; then
            file_dir="$(dirname "$file")"
            target="${file_dir}/${newbase}"
            if [ -e "$target" ] || [ -L "$target" ]; then
                echo "Warning: target already exists, skipping rename: $file -> $target"
                skipped_count=$((skipped_count + 1))
            elif [ "$dry_run" -eq 1 ]; then
                echo "Would rename: $file -> $target"
                renamed_count=$((renamed_count + 1))
            elif mv -- "$file" "$target"; then
                echo "Renamed: $file -> $target"
                renamed_count=$((renamed_count + 1))
            else
                echo "Error: failed to rename: $file -> $target" >&2
                failed_count=$((failed_count + 1))
            fi
        fi
    done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) \( "${NAME_ARGS[@]}" \) -print0)

    if [ "$rename_hits" -eq 0 ]; then
        echo "Notice: no files matching OLD_STRS found in '$dir' (rename step skipped)."
    fi

    # ------------------------------------------------------------------
    # 2) Content replacement (for *.sh and *.README regular files)
    # ------------------------------------------------------------------
    replace_hits=0
    while IFS= read -r -d '' file; do
        # Never touch the script itself
        if [ "$(readlink -f "$file" 2>/dev/null || echo "$file")" = "$SCRIPT_PATH" ]; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
        grep -E -q "$GREP_PATTERN" "$file"
        grep_status=$?
        if [ "$grep_status" -eq 1 ]; then
            continue
        elif [ "$grep_status" -ne 0 ]; then
            echo "Error: failed to inspect content: $file" >&2
            failed_count=$((failed_count + 1))
            continue
        fi

        if [ "$dry_run" -eq 1 ]; then
            echo "Would replace content: $file"
            replace_hits=$((replace_hits + 1))
            replaced_count=$((replaced_count + 1))
        elif sed -i "${SED_ARGS[@]}" "$file"; then
            echo "Content replaced: $file"
            replace_hits=$((replace_hits + 1))
            replaced_count=$((replaced_count + 1))
        else
            echo "Error: failed to replace content: $file" >&2
            failed_count=$((failed_count + 1))
        fi
    done < <(find "$dir" -maxdepth 1 -type f \( -name "*.sh" -o -name "*.README" \) -not -name "$SCRIPT_NAME" -print0)

    if [ "$replace_hits" -eq 0 ]; then
        echo "Notice: no *.sh / *.README in '$dir' contains OLD_STRS (content step skipped)."
    fi

    # ------------------------------------------------------------------
    # 3) Repair broken symlinks
    # ------------------------------------------------------------------
    while IFS= read -r -d '' link; do
        if [ "$(readlink -f "$link" 2>/dev/null || echo "$link")" = "$SCRIPT_PATH" ]; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
        if [ -e "$link" ]; then
            continue
        fi

        target="$(readlink "$link")"
        newtarget="$target"
        for i in "${!OLD_STRS[@]}"; do
            old="${OLD_STRS[$i]}"
            new="${NEW_STRS[$i]}"
            newtarget="${newtarget//$old/$new}"
        done

        if [ "$newtarget" = "$target" ]; then
            echo "Warning: broken symlink (target has no OLD_STR): $link -> $target"
            skipped_count=$((skipped_count + 1))
            continue
        fi

        if [[ "$newtarget" = /* ]]; then
            abs_newtarget="$newtarget"
        else
            abs_newtarget="$(dirname "$link")/$newtarget"
        fi

        if [ -e "$abs_newtarget" ] || [ -L "$abs_newtarget" ]; then
            if [ "$dry_run" -eq 1 ]; then
                echo "Would relink: $link -> $newtarget"
                relinked_count=$((relinked_count + 1))
            elif ln -sfn -- "$newtarget" "$link"; then
                echo "Relinked: $link -> $newtarget"
                relinked_count=$((relinked_count + 1))
            else
                echo "Error: failed to relink: $link -> $newtarget" >&2
                failed_count=$((failed_count + 1))
            fi
        else
            echo "Warning: cannot fix broken symlink: $link -> $target (tried: $newtarget)"
            skipped_count=$((skipped_count + 1))
        fi
    done < <(find "$dir" -maxdepth 1 -type l -print0)
done

# ------------------------------------------------------------------
# 4) Replace "flatcar" -> "ubinux" in ./run_local_tests.sh
# ------------------------------------------------------------------
LOCAL_TEST_SCRIPT="${SCRIPT_DIR}/run_local_tests.sh"
if [ -f "$LOCAL_TEST_SCRIPT" ]; then
    if [ "$(readlink -f "$LOCAL_TEST_SCRIPT" 2>/dev/null || echo "$LOCAL_TEST_SCRIPT")" = "$SCRIPT_PATH" ]; then
        echo "Warning: '$LOCAL_TEST_SCRIPT' is the current script, skipping."
        skipped_count=$((skipped_count + 1))
    elif [ -L "$LOCAL_TEST_SCRIPT" ]; then
        echo "Warning: '$LOCAL_TEST_SCRIPT' is a symlink, skipping to avoid modifying its target."
        skipped_count=$((skipped_count + 1))
    elif grep -q -- "flatcar" "$LOCAL_TEST_SCRIPT"; then
        if [ "$dry_run" -eq 1 ]; then
            echo "Would replace content: $LOCAL_TEST_SCRIPT (flatcar -> ubinux)"
            replaced_count=$((replaced_count + 1))
        elif sed -i 's/flatcar/ubinux/g' "$LOCAL_TEST_SCRIPT"; then
            echo "Content replaced: $LOCAL_TEST_SCRIPT (flatcar -> ubinux)"
            replaced_count=$((replaced_count + 1))
        else
            echo "Error: failed to replace content in $LOCAL_TEST_SCRIPT" >&2
            failed_count=$((failed_count + 1))
        fi
    else
        echo "No 'flatcar' found in $LOCAL_TEST_SCRIPT, skipping."
        skipped_count=$((skipped_count + 1))
    fi
else
    echo "Warning: '$LOCAL_TEST_SCRIPT' does not exist, skipping."
    skipped_count=$((skipped_count + 1))
fi

if [ "$dry_run" -eq 1 ]; then
    echo "Dry-run summary: rename=$renamed_count, content replacement=$replaced_count, relink=$relinked_count, skipped=$skipped_count, failed=$failed_count"
else
    echo "Summary: renamed=$renamed_count, content replaced=$replaced_count, relinked=$relinked_count, skipped=$skipped_count, failed=$failed_count"
fi

if [ "$failed_count" -gt 0 ]; then
    exit 1
fi

#!/usr/bin/env bash
# termux-setup-storage - Setup storage access for Termux Debian proot environment

set -e

TERMUX_PREFIX="${TERMUX_PREFIX:-/data/data/com.termux/files/usr}"
TERMUX_HOME="${TERMUX_HOME:-/data/data/com.termux/files/home}"
STORAGE_DIR="${TERMUX_HOME}/storage"

# Android storage paths
ANDROID_EXTERNAL_STORAGE="${ANDROID_EXTERNAL_STORAGE:-/storage/emulated/0}"
ANDROID_DATA_ROOT="${ANDROID_DATA_ROOT:-/storage/emulated/0}"

show_help() {
    cat << EOF
Usage: termux-setup-storage [OPTIONS]

Setup storage symlinks for accessing Android storage from Termux Debian proot.

OPTIONS:
    -h, --help       Show this help message
    -f, --force      Force recreate symlinks even if they exist
    --check          Check if storage is already setup

EXAMPLES:
    termux-setup-storage          # Setup storage symlinks
    termux-setup-storage --force  # Force recreate symlinks
    termux-setup-storage --check  # Check if storage is setup

This script creates symlinks in ~/storage pointing to Android storage directories:
    ~/storage/shared    -> /storage/emulated/0
    ~/storage/downloads -> /storage/emulated/0/Download
    ~/storage/dcim      -> /storage/emulated/0/DCIM
    ~/storage/pictures  -> /storage/emulated/0/Pictures
    ~/storage/music     -> /storage/emulated/0/Music
    ~/storage/movies    -> /storage/emulated/0/Movies

Note: This script is designed for use within Termux Debian proot environment.
      It requires proper Android storage permissions to be granted to Termux app.
EOF
}

check_storage() {
    local all_exist=true
    
    if [ ! -d "$STORAGE_DIR" ]; then
        echo "Storage directory does not exist: $STORAGE_DIR"
        return 1
    fi
    
    for link in shared downloads dcim pictures music movies; do
        if [ ! -L "$STORAGE_DIR/$link" ]; then
            echo "Missing symlink: $STORAGE_DIR/$link"
            all_exist=false
        fi
    done
    
    if $all_exist; then
        echo "Storage is properly setup"
        return 0
    else
        echo "Storage is not fully setup"
        return 1
    fi
}

setup_storage() {
    local force="${1:-false}"
    
    echo "Setting up storage access..."
    
    # Create storage directory if it doesn't exist
    if [ ! -d "$STORAGE_DIR" ]; then
        echo "Creating storage directory: $STORAGE_DIR"
        mkdir -p "$STORAGE_DIR"
    fi
    
    # Define symlink mappings
    declare -A STORAGE_LINKS=(
        ["shared"]="$ANDROID_EXTERNAL_STORAGE"
        ["downloads"]="$ANDROID_DATA_ROOT/Download"
        ["dcim"]="$ANDROID_DATA_ROOT/DCIM"
        ["pictures"]="$ANDROID_DATA_ROOT/Pictures"
        ["music"]="$ANDROID_DATA_ROOT/Music"
        ["movies"]="$ANDROID_DATA_ROOT/Movies"
    )
    
    # Create symlinks
    for link_name in "${!STORAGE_LINKS[@]}"; do
        local target_path="${STORAGE_LINKS[$link_name]}"
        local link_path="$STORAGE_DIR/$link_name"
        
        # Check if symlink already exists
        if [ -L "$link_path" ]; then
            if [ "$force" = "true" ]; then
                echo "Removing existing symlink: $link_path"
                rm -f "$link_path"
            else
                echo "Symlink already exists: $link_path -> $(readlink "$link_path")"
                continue
            fi
        fi
        
        # Create symlink
        echo "Creating symlink: $link_path -> $target_path"
        ln -s "$target_path" "$link_path"
        
        # Verify symlink was created
        if [ ! -L "$link_path" ]; then
            echo "ERROR: Failed to create symlink: $link_path"
            return 1
        fi
    done
    
    echo ""
    echo "Storage setup complete!"
    echo ""
    echo "You can now access Android storage from Termux Debian proot:"
    echo "  ~/storage/shared    - Shared storage (internal storage)"
    echo "  ~/storage/downloads - Downloads folder"
    echo "  ~/storage/dcim      - Camera photos and videos"
    echo "  ~/storage/pictures  - Pictures folder"
    echo "  ~/storage/music     - Music folder"
    echo "  ~/storage/movies    - Movies folder"
    echo ""
    echo "Note: Make sure Termux app has storage permissions granted in Android settings."
    
    return 0
}

# Parse command line arguments
FORCE=false
CHECK=false

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        --check)
            CHECK=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Execute requested action
if [ "$CHECK" = "true" ]; then
    check_storage
    exit $?
else
    setup_storage "$FORCE"
    exit $?
fi

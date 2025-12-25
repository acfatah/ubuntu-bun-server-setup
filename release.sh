#!/usr/bin/env bash
#
# An automated release script
#
# Similar to bumpp for npm packages but for bash scripts.
#
# Usage:
#   ./release.sh          # Interactive prompt for release type (patch default)
#   ./release.sh --patch  # Bump patch version (1.0.0 -> 1.0.1)
#   ./release.sh --minor  # Bump minor version (1.0.0 -> 1.1.0)
#   ./release.sh --major  # Bump major version (1.0.0 -> 2.0.0)
#   ./release.sh 2.0.0    # Set specific version

set -euo pipefail

VERSION_FILE="VERSION"
# Use a safe placeholder instead of printf-format in variables
GIT_COMMIT_MESSAGE_TEMPLATE="release: v{version}"
GIT_TAG_TEMPLATE="v{version}"

# Function to print usage
print_usage() {
    echo "Usage:"
    echo "  $0                  # Interactive prompt for release type (patch default)"
    echo "  $0 patch            # Bump patch version (1.0.0 -> 1.0.1)"
    echo "  $0 minor            # Bump minor version (1.0.0 -> 1.1.0)"
    echo "  $0 major            # Bump major version (1.0.0 -> 2.0.0)"
    echo "  $0 2.0.0            # Set specific version"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -d, --dry-run       Show what would be done without making changes"
    echo "  --patch             Shortcut to bump patch"
    echo "  --minor             Shortcut to bump minor"
    echo "  --major             Shortcut to bump major"
}

# Prompt user for release type when no arguments were provided
prompt_release_type() {
    if [ ! -t 0 ]; then
        echo "Non-interactive shell detected; defaulting to patch release."
        printf "patch"
        return
    fi

    while true; do
        cat <<'PROMPT' >&2
Select release type:
  1) patch (default)
  2) minor
  3) major
PROMPT
        read -rp "Choice [1-3]: " choice
        case "${choice,,}" in
            ""|1|patch)
                printf "patch"
                return
                ;;
            2|minor)
                printf "minor"
                return
                ;;
            3|major)
                printf "major"
                return
                ;;
            *)
                echo "Invalid choice: $choice" >&2
                ;;
        esac
    done
}

# Function to validate version format
validate_version() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Invalid version format. Use semantic versioning (e.g., 1.0.0)"
        exit 1
    fi
}

# Function to increment version
increment_version() {
    local current_version="$1"
    local increment_type="${2:-patch}"

    IFS='.' read -ra version_parts <<< "$current_version"
    local major="${version_parts[0]}"
    local minor="${version_parts[1]}"
    local patch="${version_parts[2]}"

    case "$increment_type" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            echo "Error: Invalid increment type. Use 'major', 'minor', or 'patch'"
            exit 1
            ;;
    esac

    echo "$major.$minor.$patch"
}

# Function to update version in files
update_version_in_files() {
    local new_version="$1"
    local dry_run="$2"

    echo "Updating version to $new_version..."

    # Update VERSION file
    if [ "$dry_run" = true ]; then
        echo "[DRY RUN] Would update VERSION file to $new_version"
    else
        echo "$new_version" > "$VERSION_FILE"
        echo "Updated VERSION file to $new_version"
    fi
}

# Parse command line arguments
DRY_RUN=false
INCREMENT_TYPE=""
NEW_VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_usage
            exit 0
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --major)
            INCREMENT_TYPE="major"
            shift
            ;;
        --minor)
            INCREMENT_TYPE="minor"
            shift
            ;;
        --patch)
            INCREMENT_TYPE="patch"
            shift
            ;;
        major|minor|patch)
            INCREMENT_TYPE="$1"
            shift
            ;;
        *)
            # Assume it's a specific version
            NEW_VERSION="$1"
            shift
            ;;
    esac
done

# Check if git repository exists
if [ ! -d .git ]; then
    echo "Error: Not in a git repository"
    exit 1
fi

# Get current version
if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: VERSION file not found"
    exit 1
fi

CURRENT_VERSION=$(cat "$VERSION_FILE")
echo "Current version: $CURRENT_VERSION"

# Determine new version
if [ -n "$NEW_VERSION" ]; then
    # Specific version provided
    validate_version "$NEW_VERSION"
    TARGET_VERSION="$NEW_VERSION"
else
    if [ -z "$INCREMENT_TYPE" ]; then
        INCREMENT_TYPE=$(prompt_release_type)
    fi
    # Increment based on type
    TARGET_VERSION=$(increment_version "$CURRENT_VERSION" "$INCREMENT_TYPE")
fi

echo "Target version: $TARGET_VERSION"

# Validate the new version
validate_version "$TARGET_VERSION"

# Check if working directory is clean
if ! git diff-index --quiet HEAD --; then
    if [ "$DRY_RUN" = false ]; then
        echo "Error: Git working directory is not clean. Please commit your changes first."
        exit 1
    fi
fi

# Update version in files
update_version_in_files "$TARGET_VERSION" "$DRY_RUN"

if [ "$DRY_RUN" = false ]; then
    # Commit changes
    COMMIT_MSG="${GIT_COMMIT_MESSAGE_TEMPLATE//\{version\}/$TARGET_VERSION}"
    git add "$VERSION_FILE"
    git commit -m "$COMMIT_MSG"
    echo "Committed version update: $COMMIT_MSG"

    # Create git tag
    TAG_NAME="${GIT_TAG_TEMPLATE//\{version\}/$TARGET_VERSION}"
    git tag "$TAG_NAME"
    echo "Created git tag: $TAG_NAME"

    # Push branch and tag
    CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
    git push origin "$CURRENT_BRANCH"
    echo "Pushed branch: $CURRENT_BRANCH"
    git push origin "$TAG_NAME"
    echo "Pushed tag: $TAG_NAME"

    echo ""
    echo "Release completed successfully!"
    echo "Version: $CURRENT_VERSION -> $TARGET_VERSION"
    echo "Tag: $TAG_NAME"
else
    echo ""
    echo "[DRY RUN] Would perform the following actions:"
    echo "1. Update VERSION file from $CURRENT_VERSION to $TARGET_VERSION"
    echo "2. Commit with message: ${GIT_COMMIT_MESSAGE_TEMPLATE//\{version\}/$TARGET_VERSION}"
    echo "3. Create git tag: ${GIT_TAG_TEMPLATE//\{version\}/$TARGET_VERSION}"
fi

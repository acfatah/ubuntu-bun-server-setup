# Releasing ubuntu-bun-installer

This project includes an automated release system similar to `bumpp` for npm packages but designed for bash script projects.

## Version Management

The project uses semantic versioning (SemVer) with a `VERSION` file in the root directory that tracks the current version.

## Release Commands

### Using the release script directly:

```bash
# Bump patch version (1.0.0 -> 1.0.1)
./release.sh

# Bump minor version (1.0.0 -> 1.1.0)
./release.sh minor

# Bump major version (1.0.0 -> 2.0.0)
./release.sh major

# Set specific version
./release.sh 2.0.0

# Dry run - show what would be done without making changes
./release.sh --dry-run
./release.sh --dry-run minor
```

### Using make commands:

```bash
# Bump patch version (default)
make release

# Bump major version
make release-major

# Bump minor version
make release-minor

# Bump patch version (explicit)
make release-patch
```

## What the release process does:

1. Updates the `VERSION` file with the new version
2. Creates a git commit with the message "release: v[version]"
3. Creates a git tag with the format "v[version]"
4. Provides instructions for pushing changes

## After releasing:

After running a release command, you'll need to push the changes and tags to the remote repository:

```bash
git push origin main
git push origin v[version]
```

For example, if you released version 1.2.3:
```bash
git push origin main
git push origin v1.2.3
```

## Requirements:

- Git repository with clean working directory (no uncommitted changes)
- VERSION file in the root directory
- Proper permissions to create commits and tags

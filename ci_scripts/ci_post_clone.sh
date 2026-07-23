#!/bin/sh

# Xcode Cloud post-clone step.
#
# The Xcode project is generated from `project.yml` by XcodeGen and is not
# committed to the repository (see .gitignore). Xcode Cloud clones the repo and
# then immediately tries to resolve packages against `Discourse.xcodeproj`,
# which doesn't exist yet — so we generate it here, before the build.

set -e

echo "▸ Installing XcodeGen…"
if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen
fi

echo "▸ Generating Discourse.xcodeproj from project.yml…"
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate

# Xcode Cloud resolves packages with "only use versions from Package.resolved"
# enforced, but the freshly generated project has no resolved file. Drop the
# committed, pinned one into the workspace so resolution is deterministic.
echo "▸ Installing pinned Package.resolved…"
SWIFTPM_DIR="Discourse.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$SWIFTPM_DIR"
cp ci_scripts/Package.resolved "$SWIFTPM_DIR/Package.resolved"

echo "▸ Done — project generated and dependencies pinned."

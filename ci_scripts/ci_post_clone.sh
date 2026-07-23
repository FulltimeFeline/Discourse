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

echo "▸ Done — project generated."

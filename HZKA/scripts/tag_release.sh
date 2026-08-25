#!/usr/bin/env bash
# ===========================================================================
# H-ZKA: Tag and push the third-revision release.
#
# This script implements TODO Section 4, Item 9:
#   1. Tag commit a103cad9 as v3.0-jsa-r3
#   2. Push the tag to origin
#   3. Print the tag URL for the bibliography entry
#
# Usage:
#   bash tag_release.sh
# ===========================================================================

set -euo pipefail

COMMIT="a103cad9"
TAG="v3.0-jsa-r3"
MESSAGE="JSA third revision"

echo "== H-ZKA Release Tag =="
echo "Commit:  ${COMMIT}"
echo "Tag:     ${TAG}"
echo "Message: ${MESSAGE}"
echo

# Check if the commit exists
if ! git rev-parse --verify "${COMMIT}" >/dev/null 2>&1; then
    echo "ERROR: Commit ${COMMIT} not found in the repository."
    echo "Please verify the commit hash and try again."
    exit 1
fi

# Check if the tag already exists
if git rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "WARNING: Tag ${TAG} already exists."
    echo "Existing tag points to: $(git rev-parse refs/tags/${TAG})"
    echo "To re-tag, first delete: git tag -d ${TAG} && git push origin :refs/tags/${TAG}"
    exit 0
fi

# Create annotated tag
echo "Creating annotated tag..."
git tag -a "${TAG}" -m "${MESSAGE}" "${COMMIT}"
echo "Tag ${TAG} created successfully."

# Push to origin
echo "Pushing tag to origin..."
git push origin "${TAG}"
echo "Tag pushed."

# Print URL for bibliography
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "UNKNOWN")
echo
echo "== Bibliography entry update =="
echo "Add to the hzka_artifact bibliography entry:"
echo "  tag = {${TAG}},"
echo "  url = {${REMOTE_URL}/releases/tag/${TAG}},"
echo
echo "Done."

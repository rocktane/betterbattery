#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# --- Prerequisites ---
command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI is required (brew install gh)"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Error: not a git repository"; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "Error: no git remote 'origin' — run 'make init-github' first"; exit 1; }

PLIST="Info.plist"
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

echo ""
echo "  Current version: v$CURRENT"
echo ""
echo "  1) patch  → v$MAJOR.$MINOR.$((PATCH + 1))"
echo "  2) minor  → v$MAJOR.$((MINOR + 1)).0"
echo "  3) major  → v$((MAJOR + 1)).0.0"
echo ""
read -rp "  Bump type [1/2/3]: " CHOICE

case "$CHOICE" in
  1) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  2) NEW="$MAJOR.$((MINOR + 1)).0" ;;
  3) NEW="$((MAJOR + 1)).0.0" ;;
  *) echo "Invalid choice"; exit 1 ;;
esac

# Check tag doesn't already exist
if git rev-parse "v$NEW" >/dev/null 2>&1; then
  echo "Error: tag v$NEW already exists"
  exit 1
fi

echo ""
read -rp "  Release v$NEW? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "Cancelled."; exit 0; }

# --- Bump version in Info.plist ---
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" "$PLIST"

# --- Commit, tag, push ---
BRANCH=$(git symbolic-ref --short HEAD)
git add -A
git commit -m "v$NEW"
git tag -a "v$NEW" -m "v$NEW"
git push origin "$BRANCH" --follow-tags

echo ""
echo "  v$NEW pushed — GitHub Actions will build the release and update Homebrew."
echo ""

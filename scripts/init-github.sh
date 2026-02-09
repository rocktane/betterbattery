#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# --- Prerequisites ---
command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI is required (brew install gh)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: run 'gh auth login' first"; exit 1; }

GITHUB_USER=$(gh api user -q .login)
REPO="betterbattery"
TAP="homebrew-tap"

echo ""
echo "  Setting up GitHub for $GITHUB_USER..."
echo ""

# --- 1. Init git repo ---
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init
  git add -A
  git commit -m "Initial commit"
  echo "  [ok] Git repo initialized"
fi

# --- 2. Create main repo ---
if ! gh repo view "$GITHUB_USER/$REPO" >/dev/null 2>&1; then
  gh repo create "$REPO" --public --source=. --push
  echo "  [ok] Created github.com/$GITHUB_USER/$REPO"
else
  echo "  [ok] github.com/$GITHUB_USER/$REPO already exists"
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "https://github.com/$GITHUB_USER/$REPO.git"
  fi
  git push -u origin main 2>/dev/null || true
fi

# --- 3. Create tap repo ---
if ! gh repo view "$GITHUB_USER/$TAP" >/dev/null 2>&1; then
  # Create the repo
  gh repo create "$TAP" --public --description "Homebrew tap for BetterBattery"

  # Set up initial cask in a temp clone
  TMPDIR=$(mktemp -d)
  git clone "https://github.com/$GITHUB_USER/$TAP.git" "$TMPDIR" 2>/dev/null || {
    cd "$TMPDIR"
    git init
    git remote add origin "https://github.com/$GITHUB_USER/$TAP.git"
    git checkout -b main
  }

  cd "$TMPDIR"
  mkdir -p Casks

  cat > Casks/betterbattery.rb << CASK
cask "betterbattery" do
  version "0.0.0"
  sha256 "placeholder"

  url "https://github.com/$GITHUB_USER/$REPO/releases/download/v#{version}/BetterBattery.zip"
  name "BetterBattery"
  desc "macOS menu bar battery charge limiter"
  homepage "https://github.com/$GITHUB_USER/$REPO"

  app "BetterBattery.app"
end
CASK

  git add -A
  git commit -m "Initial tap with betterbattery cask"
  git branch -M main
  git push -u origin main

  cd -
  rm -rf "$TMPDIR"
  echo "  [ok] Created github.com/$GITHUB_USER/$TAP"
else
  echo "  [ok] github.com/$GITHUB_USER/$TAP already exists"
fi

# --- 4. Deploy key for CI → tap pushes ---
echo ""
echo "  Setting up deploy key for CI..."

TMPKEY=$(mktemp)
rm -f "$TMPKEY"  # ssh-keygen needs the file to not exist
ssh-keygen -t ed25519 -f "$TMPKEY" -N "" -q -C "betterbattery-release-bot"

# Add public key as deploy key (write access) to tap repo
gh api "repos/$GITHUB_USER/$TAP/keys" \
  -f title="BetterBattery Release Bot" \
  -f key="$(cat "$TMPKEY.pub")" \
  -F read_only=false > /dev/null

# Store private key as secret in main repo
gh secret set TAP_DEPLOY_KEY -R "$GITHUB_USER/$REPO" < "$TMPKEY"

rm -f "$TMPKEY" "$TMPKEY.pub"
echo "  [ok] Deploy key configured"

echo ""
echo "  Done! Usage:"
echo ""
echo "    make release    # bump version, push, auto-build & update Homebrew"
echo ""
echo "  Users install with:"
echo ""
echo "    brew tap $GITHUB_USER/tap"
echo "    brew install --cask betterbattery"
echo ""

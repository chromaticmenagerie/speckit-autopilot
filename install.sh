#!/usr/bin/env bash
# install.sh — Install speckit-autopilot into a Spec Kit project.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/chromaticmenagerie/speckit-autopilot/main/install.sh | bash
#
# Or from a local clone:
#   ./install.sh
#
# Prerequisites: Spec Kit must already be installed (.specify/ directory exists).

set -euo pipefail

REPO_URL="https://github.com/chromaticmenagerie/speckit-autopilot"
TARBALL_URL="https://github.com/chromaticmenagerie/speckit-autopilot/archive/refs/heads/main.tar.gz"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { echo -e "${GREEN}[autopilot]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[autopilot]${RESET} $1"; }
error() { echo -e "${RED}[autopilot]${RESET} $1" >&2; }
die()   { error "$1"; exit 1; }

# ─── Step 1: Preflight — verify Spec Kit installed ──────────────────────────

if [[ ! -d ".specify" ]]; then
    die "Spec Kit not found: .specify/ directory does not exist.
    Install Spec Kit first, then re-run this installer."
fi

if [[ ! -f ".specify/scripts/bash/common.sh" ]]; then
    die "Spec Kit incomplete: .specify/scripts/bash/common.sh is missing.
    Reinstall Spec Kit, then re-run this installer."
fi

if [[ ! -d ".specify/templates" ]]; then
    die "Spec Kit incomplete: .specify/templates/ directory is missing.
    Reinstall Spec Kit, then re-run this installer."
fi

info "Spec Kit detected"

# ─── Step 2: Determine source directory ──────────────────────────────────────

SRC_DIR=""
CLEANUP_DIR=""

# Check if running from a local clone (install.sh is in the repo root with src/)
# When piped via curl|bash, BASH_SOURCE is unset — fall back to download path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/null}")" 2>/dev/null && pwd || echo "")"
if [[ -n "$SCRIPT_DIR" ]] && [[ -d "$SCRIPT_DIR/src" ]] && [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    SRC_DIR="$SCRIPT_DIR"
    info "Installing from local clone: $SRC_DIR"
else
    # Download from GitHub
    info "Downloading from $REPO_URL ..."
    TMPDIR=$(mktemp -d)
    CLEANUP_DIR="$TMPDIR"

    if command -v curl >/dev/null 2>&1; then
        curl -sSL "$TARBALL_URL" | tar xz -C "$TMPDIR"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$TARBALL_URL" | tar xz -C "$TMPDIR"
    else
        die "Neither curl nor wget found. Install one and retry."
    fi

    # GitHub tarballs extract to speckit-autopilot-main/
    SRC_DIR="$TMPDIR/speckit-autopilot-main"
    if [[ ! -d "$SRC_DIR" ]]; then
        die "Download failed: expected $SRC_DIR after extraction."
    fi
    info "Downloaded successfully"
fi

# Verify source has expected structure
if [[ ! -f "$SRC_DIR/VERSION" ]]; then
    die "Invalid source: VERSION file not found in $SRC_DIR"
fi

NEW_VERSION=$(<"$SRC_DIR/VERSION")
NEW_VERSION="${NEW_VERSION%$'\n'}"  # trim trailing newline

# ─── Step 3: Version check ──────────────────────────────────────────────────

VERSION_FILE=".specify/autopilot-version"

if [[ -f "$VERSION_FILE" ]]; then
    INSTALLED_VERSION=$(<"$VERSION_FILE")
    INSTALLED_VERSION="${INSTALLED_VERSION%$'\n'}"

    if [[ "$INSTALLED_VERSION" == "$NEW_VERSION" ]]; then
        info "Already up to date (v${NEW_VERSION})"
        if [[ -n "$CLEANUP_DIR" ]]; then rm -rf "$CLEANUP_DIR"; fi
        exit 0
    fi
    info "Upgrading: v${INSTALLED_VERSION} → v${NEW_VERSION}"
else
    info "Fresh install: v${NEW_VERSION}"
fi

# ─── Step 4: Copy script files ──────────────────────────────────────────────

DEST=".specify/scripts/bash"
mkdir -p "$DEST"

for script in autopilot.sh autopilot-lib.sh autopilot-stream.sh autopilot-prompts.sh autopilot-detect-project.sh autopilot-github.sh autopilot-github-sync.sh autopilot-coderabbit.sh autopilot-finalize.sh autopilot-watch.sh common.sh; do
    if [[ -f "$SRC_DIR/src/$script" ]]; then
        cp "$SRC_DIR/src/$script" "$DEST/$script"
        chmod +x "$DEST/$script"
    else
        warn "Missing source file: src/$script (skipped)"
    fi
done

info "Scripts installed to $DEST/"

# ─── Step 5: Install skill file ─────────────────────────────────────────────

SKILL_DEST=".claude/skills/autopilot"
mkdir -p "$SKILL_DEST"

if [[ -f "$SRC_DIR/skill/autopilot/SKILL.md" ]]; then
    cp "$SRC_DIR/skill/autopilot/SKILL.md" "$SKILL_DEST/SKILL.md"
    info "Skill registered: /autopilot (in $SKILL_DEST/)"
else
    warn "Skill file not found in source (skipped)"
fi

# Remove legacy command if present (pre-v0.2.0)
if [[ -f ".claude/commands/autopilot.md" ]]; then
    rm -f ".claude/commands/autopilot.md"
    rmdir ".claude/commands" 2>/dev/null || true
    info "Cleaned up legacy .claude/commands/autopilot.md"
fi

# ─── Step 6: Write version marker ───────────────────────────────────────────

echo "$NEW_VERSION" > "$VERSION_FILE"

# ─── Step 7: Detect project tooling ─────────────────────────────────────────

if [[ ! -f ".specify/project.env" ]]; then
    info "Detecting project tooling..."
    if [[ -x "$DEST/autopilot-detect-project.sh" ]]; then
        bash "$DEST/autopilot-detect-project.sh"
    else
        warn "Could not run project detection — create .specify/project.env manually"
    fi
else
    info "project.env already exists — skipping detection (use --force to regenerate)"
fi

# ─── Step 8: Cleanup ────────────────────────────────────────────────────────

if [[ -n "$CLEANUP_DIR" ]]; then
    rm -rf "$CLEANUP_DIR"
fi

# ─── Step 9: Success ────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║${RESET}  ${GREEN}Autopilot v${NEW_VERSION} installed successfully${RESET}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}║${RESET}  Skill:  /autopilot (in .claude/skills/autopilot/)"
echo -e "${BOLD}║${RESET}  Config: .specify/project.env (review and adjust)"
echo -e "${BOLD}║${RESET}"
echo -e "${BOLD}║${RESET}  Next: Create epics in docs/specs/epics/"
echo -e "${BOLD}║${RESET}        then run /autopilot"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

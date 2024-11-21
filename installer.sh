#!/bin/bash
set -e

# Global color definitions
readonly RESET='\033[0m'
readonly BOLD='\033[1m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'

# Globar variables
DEV_MODE=false
SOURCE_DIR=""
INSTALL_DIR=""
INSTALL_LIB_DIR=""
VERSION=""

# Detect OS and set the installation directory or exit
case "$(uname -s)" in
  Linux|Darwin)
    INSTALL_DIR="/usr/local/bin"
    INSTALL_LIB_DIR="/usr/local/lib/c2p"
  ;;
  FreeBSD|OpenBSD|NetBSD)
    INSTALL_DIR="/usr/local/bin"
    INSTALL_LIB_DIR="/usr/local/lib/c2p"
  ;;
  CYGWIN*|MINGW32*|MSYS*|MINGW*)
    INSTALL_DIR="/c/Program Files/c2p"
    INSTALL_LIB_DIR="/c/Program Files/c2p/lib"
  ;;
  *)
    echo -e "${COLOR_RED}${BOLD}Unsupported OS. Please install manually.${RESET}"
    exit 1
  ;;
esac

# Check for required dependencies
check_dependencies() {
  # Core dependencies required by the scripts
  local deps=("sed" "git" "grep")
  local min_bash_vers="3.2"
  local missing_deps=()

  # Check bash version first
  if command -v bash &>/dev/null; then
    local bash_vers
    bash_vers=$(bash --version | head -n1 | sed 's/.*version \([0-9]*\)\.\([0-9]*\).*/\1.\2/g')
    if ! (($(echo "$bash_vers >= $min_bash_vers" | bc -l))); then
      echo -e "${COLOR_RED}${BOLD}bash version should be $min_bash_vers or newer (found: $bash_vers) ${RESET}"
      exit 1
    fi
  else
    echo -e "${COLOR_RED}${BOLD}bash not found!${RESET}"
    exit 1
  fi

  # Check other dependencies
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      missing_deps+=("$dep")
    fi
  done

  # If there are missing dependencies, print them and exit
  if [ ${#missing_deps[@]} -gt 0 ]; then
    echo -e "${COLOR_RED}${BOLD}Missing required dependencies${RESET}"
    printf '%s\n' "${missing_deps[@]}" | sed 's/^/  - /'
    if [ ${#missing_deps[@]} -gt 1 ]; then
      echo -e "\n Please install them, and try again."
    else
      echo -e "\n Please install it, and try again."
    fi
    exit 1
  fi

  return 0
}

check_dependencies

# Check if running with sudo/root permissions
# shellcheck disable=SC2120
check_permissions() {
  if [ "$EUID" -ne 0 ]; then 
    echo -e "${COLOR_RED}${BOLD}This script requires root privileges to install to system directories.${RESET}"
    echo "Please run with sudo: sudo $0 $*"
    exit 1
  fi
}

check_permissions

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --dev) 
      DEV_MODE=true
      VERSION='development'
      shift
    ;;
    *) 
      shift
    ;;
  esac
done

# Run the build script in dev mode
if [ "$DEV_MODE" = true ]; then
  echo "Running build script in dev mode..."
  SOURCE_DIR="src"
else
  echo -e "${BOLD}Released build is yet not available${RESET}"
fi

echo "Installing c2p version $VERSION..."

# Clean up existing installation
rm -rf "$INSTALL_LIB_DIR"
rm -f "$INSTALL_DIR/c2p"

# Create lib directory
mkdir -p "$INSTALL_LIB_DIR"

# First set executable permissions on source files before copying
chmod +x "$SOURCE_DIR/c2p.sh"

# Copy files and preserve permissions (-p flag)
cp -p "$SOURCE_DIR"/*.sh "$INSTALL_LIB_DIR/"

# Ensure correct permissions on all files
chmod 644 "$INSTALL_LIB_DIR"/*.sh
chmod 755 "$INSTALL_LIB_DIR/c2p.sh"

# Create symlink
ln -sf "$INSTALL_LIB_DIR/c2p.sh" "$INSTALL_DIR/c2p"

# Verify installation
if [ -L "$INSTALL_DIR/c2p" ] && [ -x "$INSTALL_LIB_DIR/c2p.sh" ]; then
    echo -e "${COLOR_GREEN}${BOLD}Installation complete.${RESET} Run 'c2p --help' to get started."
else
    echo -e "${COLOR_RED}${BOLD}Error: Installation failed. The executable could not be properly installed.${RESET}"
    exit 1
fi
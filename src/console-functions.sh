#!/bin/bash
#
# Copyright 2024 Sourav Ray
#
# Console output utility functions for c2p.sh
#

# Global color definitions
readonly RESET='\033[0m'
readonly BOLD='\033[1m'

# Text Color Codes
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_YELLOW='\033[0;33m'

# Helper function to print logs
print_fn_log() {
  local level="$1"
  local message="$2"
  
  # Select color based on log level
  local color
  case "$level" in
    "Error") color="$COLOR_MAGENTA" ;;
    "Warning") color="$COLOR_YELLOW" ;;
    *) color="$RESET" ;; # Default to no color
  esac

  # Print the message with color to stderr
  # Printing info also in stderr, since stdout might be redirected
  echo -e "${color}[$level] ${RESET} $message" >&2
}

# Helper function to print emphasized text
print_fn_heading() {
  local color=""
  local firstParam="$1"
  
  case "$firstParam" in
    "Success")
      shift
      color="$COLOR_GREEN"
    ;;
    "Failure")
      shift
      color="$COLOR_RED"
    ;;
    "Alert")
      shift
      color="$COLOR_YELLOW"
    ;;
    "Notify")
      shift
      color="$COLOR_BLUE"
    ;;
    *) ;;
  esac

  # Check if stdout is redirected
  if ! tty -s; then
    # stdout is redirected, so print to stderr
    echo -e "${color}░░  ${BOLD}$*${RESET}" >&2
  else
    # stdout is not redirected, print to stdout
    echo -e "${color}░░  ${BOLD}$*${RESET}"
  fi
}
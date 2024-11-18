#!/bin/bash

#
# Copyright 2024 Sourav Ray
#
# Git utility functions for c2p.sh
#

# Store the project directory for Git operations
PROJECT_DIR=""
ORIGINAL_BRANCH=""
REVIEW_BRANCH=""
CLEANUP_NEEDED=false

# Set the project directory for Git operations
set_project_dir() {
  # Resolve the absolute path
  PROJECT_DIR="$(cd "$1" 2>/dev/null && pwd)" || {
    echo "Error: Failed to resolve project directory: $1"
    return 1
  }
  export PROJECT_DIR
  echo "Set project directory to: $PROJECT_DIR"
}

# Store the original branch name
store_original_branch() {
  ORIGINAL_BRANCH=$(git_in_project git rev-parse --abbrev-ref HEAD) || {
    echo "Error: Failed to get current branch name"
    return 1
  }
  export ORIGINAL_BRANCH
}

# Run git command in project directory
git_in_project() {
  (cd "$PROJECT_DIR" && "$@")
}

# Initialize a new Git repository
init_git_repo() {
  local dir="$1"
  local abs_dir parent_dir
  
  abs_dir="$(cd "$dir" 2>/dev/null && pwd)" || {
    parent_dir="$(cd "$(dirname "$dir")" 2>/dev/null && pwd)"
    abs_dir="${parent_dir}/$(basename "$dir")"
  }
  
  echo "Initializing Git repository in: $abs_dir"
  git init "$abs_dir" || return 1
  set_project_dir "$abs_dir" || return 1
}

# Check if there is detached HEAD
check_detached_head() {
  if git_in_project git rev-parse --abbrev-ref HEAD | grep -q "HEAD"; then
    echo "Error: HEAD is detached. Please checkout a branch before proceeding."
    return 1
  fi
}

# Check if working tree is clean
check_working_tree_clean() {
  if ! git_in_project git diff-index --quiet HEAD --; then
    echo "Error: You have unsaved changes. Please commit or stash them before updating."
    return 1
  fi
}

# Create a new review branch
create_review_branch() {
  local current_review new_review
  current_review=$(git_in_project git branch | grep -c "review-patch/")
  new_review=$((current_review + 1))
  REVIEW_BRANCH="review-patch/$new_review"
  export REVIEW_BRANCH

  # Store the current branch name before creating review branch
  store_original_branch || return 1

  git_in_project git checkout -b "$REVIEW_BRANCH" || {
    echo "Error: Failed to create new review branch" >&2
    return 1
  }

  CLEANUP_NEEDED=true
  export CLEANUP_NEEDED

  # Return both branch names in format "origin_branch:review_branch"
  echo "${ORIGINAL_BRANCH}:${REVIEW_BRANCH}"
}

# Cleanup function to restore git state
# shellcheck disable=SC2120
cleanup_git_state() {
  local force_cleanup="${1:-false}"
  
  if [ "$CLEANUP_NEEDED" = true ] || [ "$force_cleanup" = true ]; then
    echo "Performing git state cleanup..."
    
    # Check if we're in a git repository
    if ! git_in_project git rev-parse --git-dir > /dev/null 2>&1; then
      echo "Not in a git repository, skipping cleanup"
      return 0
    fi

    # Store current branch
    local current_branch
    current_branch=$(git_in_project git rev-parse --abbrev-ref HEAD)

    # If we're in the middle of a merge, abort it
    if [ -f "$PROJECT_DIR/.git/MERGE_HEAD" ]; then
      echo "Aborting incomplete merge..."
      git_in_project git merge --abort
    fi

    # Reset any staged changes
    git_in_project git reset --quiet

    # Clean untracked files and directories
    git_in_project git clean -fd --quiet

    # Restore original branch if we're on review branch
    if [ -n "$ORIGINAL_BRANCH" ] && [ "$current_branch" != "$ORIGINAL_BRANCH" ]; then
      echo "Restoring original branch: $ORIGINAL_BRANCH"
      if git_in_project git checkout "$ORIGINAL_BRANCH"; then
        # Delete review branch if it exists
        if [ -n "$REVIEW_BRANCH" ] && git_in_project git branch --list "$REVIEW_BRANCH" | grep -q "$REVIEW_BRANCH"; then
          echo "Removing review branch: $REVIEW_BRANCH"
          git_in_project git branch -D "$REVIEW_BRANCH"
        fi
      else
        echo "Warning: Failed to restore original branch"
      fi
    fi

    # Reset flags
    CLEANUP_NEEDED=false
    REVIEW_BRANCH=""
    echo "Cleanup completed"
  fi
}

# [Previous functions remain unchanged...]

# Modified perform_merge function with cleanup handling
perform_merge() {
  local review_branch="$1"
  local origin_branch="$2"
  local merge_successful=false
  
  if [ -z "$origin_branch" ]; then
    echo "Error: Could not determine origin branch"
    cleanup_git_state
    return 1
  fi

  if ! git_in_project git checkout "$origin_branch"; then
    echo "Error: Failed to checkout $origin_branch branch"
    cleanup_git_state
    return 1
  fi

  # Merge changes
  if ! git_in_project git merge --no-commit --no-ff "$review_branch"; then
    echo "Error: Merge conflicts detected"
    cleanup_git_state
    return 1
  fi

  # Review merge conflicts
  if ! git_in_project git diff --cached; then
    configure_merge_tool
    if ! (cd "$PROJECT_DIR" && git mergetool --no-commit); then
      echo "Error: Merge tool operation failed"
      cleanup_git_state
      return 1
    fi

    # Review merged changes
    git_in_project git diff --cached

    read -rp "Proceed with merge commit? (y/n): " proceed
    if [[ $proceed == "y" ]]; then
      if git_in_project git commit; then
        merge_successful=true
      else
        echo "Error: Failed to commit merge"
        cleanup_git_state
        return 1
      fi
    else
      git_in_project git merge --abort
      cleanup_git_state
      return 1
    fi
  else
    if git_in_project git commit; then
      merge_successful=true
    else
      echo "Error: Failed to commit merge"
      cleanup_git_state
      return 1
    fi
  fi

  git_in_project git clean -f

  # Delete review branch if merge was successful
  if [ "$merge_successful" = true ]; then
    echo "Cleaning up review branch: $review_branch"
    if ! git_in_project git branch -D "$review_branch"; then
      echo "Warning: Failed to delete review branch $review_branch"
    fi
    echo "Project updated and review branch cleaned up successfully"
    CLEANUP_NEEDED=false
  else
    echo "Merge was not completed, review branch $review_branch retained"
    cleanup_git_state
    return 1
  fi
}

#!/bin/bash

#
# Copyright 2024 Sourav Ray
#
# Git utility functions for c2p.sh
#

# Store the project directory for Git operations
PROJECT_DIR=""

# Set the project directory for Git operations
set_project_dir() {
  # Resolve the absolute path
  PROJECT_DIR="$(cd "$1" 2>/dev/null && pwd)" || {
    echo "Error: Failed to resolve project directory: $1"
    exit 1
  }
  export PROJECT_DIR
  echo "Set project directory to: $PROJECT_DIR"
}

# Run git command in project directory
git_in_project() {
  (cd "$PROJECT_DIR" && "$@")
}

# Initialize a new Git repository
init_git_repo() {
  local dir="$1"
  local abs_dir parent_dir
  # Ensure we have the absolute path
  abs_dir="$(cd "$dir" 2>/dev/null && pwd)" || {
    # If directory doesn't exist yet, get absolute path of parent and append dir name
    parent_dir="$(cd "$(dirname "$dir")" 2>/dev/null && pwd)"
    abs_dir="${parent_dir}/$(basename "$dir")"
  }
  
  echo "Initializing Git repository in: $abs_dir"
  git init "$abs_dir" || {
    echo "Error: Failed to initialize Git repository"
    exit 1
  }
  set_project_dir "$abs_dir"
}

# Check if there is detached HEAD
check_detached_head() {
  if git_in_project git rev-parse --abbrev-ref HEAD | grep -q "HEAD"; then
    echo "Error: HEAD is detached. Please checkout a branch before proceeding."
    exit 1
  fi
}

# Check if working tree is clean
check_working_tree_clean() {
  if ! git_in_project git diff-index --quiet HEAD --; then
    echo "Error: You have unsaved changes. Please commit or stash them before updating."
    exit 1
  fi
}

# Create a new review branch
create_review_branch() {
  local current_review new_review origin_branch review_branch
  current_review=$(git_in_project git branch | grep -c "review-patch/")
  new_review=$((current_review + 1))
  review_branch="review-patch/$new_review"

  # Store the current branch name
  origin_branch=$(git_in_project git rev-parse --abbrev-ref HEAD)
  if [ -z "$origin_branch" ]; then
    echo "Error: Failed to get current branch name" >&2
    exit 1
  fi

  git_in_project git checkout -b "$review_branch" || {
    echo "Error: Failed to create new review branch" >&2
    exit 1
  }

  # Return both branch names in format "origin_branch:review_branch"
  echo "${origin_branch}:${review_branch}"
}

# Configure merge tool interactively
configure_merge_tool() {
  echo "No merge tool configured. Available merge tools:"
  echo "1. vimdiff"
  echo "2. meld"
  echo "3. kdiff3"
  echo "4. opendiff"
  
  read -rp "Choose a merge tool (1-4): " choice
  
  case $choice in
    1) tool="vimdiff" ;;
    2) tool="meld" ;;
    3) tool="kdiff3" ;;
    4) tool="opendiff" ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
  
  git_in_project git config merge.tool "$tool"
  git_in_project git config mergetool.prompt false
}

# External merge tools related functions
# Get available merge tools
_get_available_tools() {
  # Initialize variables first
  local supported_tools=("vimdiff" "nvimdiff" )
  local available_tools=()
  local choice
  local tool
  
  # Clear any pending input
  read -rt 0.1 -n 10000 || true

  # Add VS Code if available
  if command -v code >/dev/null 2>&1; then
    available_tools+=("code")
  fi
    
  # Check which supported tools are available
   while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+Use ]]; then
      tool="${BASH_REMATCH[1]}"
      tool="$(echo "$tool" | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | tr -d '[:space:]')"
      # Check if the tool is in our supported list using proper array containment check
      for supported_tool in "${supported_tools[@]}"; do
        if [[ "$tool" == "$supported_tool" ]]; then
          # Add tool to the list of Avilale Tools
            available_tools+=("$tool")
          break
        fi
      done
    fi
  done < <(git mergetool --tool-help | sed -n '/may be set to one of the following:/,/The following tools are valid, but not currently available:/p')

  # Print menu and get choice
  {
    echo "Available merge options:"
    for i in "${!available_tools[@]}"; do
      echo "$((i+1)). ${available_tools[i]}"
    done
    echo "$((${#available_tools[@]}+1)). Use git add -p (default)"
    echo -n "Choose a merge option (1-$((${#available_tools[@]}+1))): "
  } > /dev/tty

  # Read from /dev/tty explicitly
  read -r choice < /dev/tty

  # Force output buffer flush
  if [ "$choice" -le "${#available_tools[@]}" ] && [ "$choice" -ge 1 ]; then
    printf '%s' "${available_tools[$((choice-1))]}"
  else
    printf ''
  fi
}

# Stage and commit related functions
# Helper function to get relative path for git operations
_get_relative_path() {
  local file="$1"
  local relative_path
  if [[ "$file" = /* ]]; then
    # If absolute path, make it relative to PROJECT_DIR
    relative_path="${file#"$PROJECT_DIR"/}"
  else
    # If already relative, use as is
    relative_path="$file"
  fi
  echo "$relative_path"
}

# Function to stage changes using mergetool
# a better version of `git add -p <file>`, 
# inspired by Stuart Berg's https://github.com/stuarteberg/stuart-scripts/blob/master/add-with-mergetool
_stage_file_with_mergetool() {
  local file="$1"
  local tool="$2"
  local relative_file_path repo_toplevel status
  
  relative_file_path="$(_get_relative_path "$file")"
  echo "Reviewing diff: $relative_file_path"
  
  if [ ! -f "$relative_file_path" ]; then
    echo "Warning: File not found: $relative_file_path"
    return 0
  fi
  
  repo_toplevel=$(git rev-parse --show-toplevel)
  
  (cd "$repo_toplevel" && {
    # Create temporary files with meaningful names
    local index_file="$relative_file_path.from_index"
    # local merged_file="$relative_file_path.to_add" # If support kdiff3 or similar tools in future
    local backup_file="$relative_file_path.working_tree"
    
    # Get the version from index
    git show :"$relative_file_path" > "$index_file"

    # Set up merge tool command based on tool
    local merge_cmd 
    case "$tool" in
      "code")
        merge_cmd="code --wait --diff \"$index_file\" \"$relative_file_path\""
        ;;
      "vimdiff"|"nvimdiff")
        # Using -d for side-by-side diff mode
        merge_cmd="$tool -d \"$index_file\" \"$relative_file_path\""
        ;;
      *)
        echo "Error: Unsupported merge tool '$tool'"
        rm -f "$index_file"
        return 1
        ;;
    esac
    
    # Execute merge
    echo "Launching $tool for '$relative_file_path'."

    # For tools that handle waiting themselves
    eval "$merge_cmd"
    status=$?
    
    if [ $status -eq 0 ]; then
      # Backup working tree version
      cp "$relative_file_path" "$backup_file"
      
      # Stage the changes
      git add "$relative_file_path"
      
      # Restore working tree version
      mv "$backup_file" "$relative_file_path"
    fi
    
    # Cleanup
      rm -f "$index_file"
      rm -f "$backup_file"
    
    return $status
  })
}

# Helper function to stage a single file
_stage_file() {
  local file="$1"
  local review="$2"
  local relative_path
  
  relative_path="$(_get_relative_path "$file")"
  echo "Processing file: $relative_path"
  
  if [ ! -f "$relative_path" ]; then
    echo "Warning: File not found: $relative_path"
    return 0
  fi
  
  if [ "$review" = true ]; then
    clear
    echo "Review and staging changes in: $relative_path"
    sleep 2
    clear
    git add -p "$relative_path" || {
      echo "Error: Failed to stage $relative_path"
      return 1
    }
  else
    git add "$relative_path" || {
      echo "Error: Failed to stage $relative_path"
      return 1
    }
  fi
}

# Helper function to handle commit
_commit_changes() {
  local message="$1"
  local discard_unstaged="$2"
  
  echo "Committing changes with message: $message"
  git commit -m "$message" || {
    echo "Error: Failed to commit changes"
    return 1
  }
  
  if [ "$discard_unstaged" = true ]; then
    git restore .
  fi
}

# Function to stage and commit files with options
stage_and_commit_files() {
  local message="$1"
  local review=${2:-false}  # Optional parameter for review mode
  shift
  local files=("$@")
  local merge_tool
  
  echo "Staging files in: $PROJECT_DIR"
  
  if [ "$review" = true ]; then
    # Get user's preferred merge tool
    merge_tool=$(_get_available_tools)
    merge_tool="$(echo "$merge_tool" | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | tr -d '[:space:]')"
  fi
    
  # Change to project directory
  (cd "$PROJECT_DIR" && {
    # Stage each file
    for file in "${files[@]}"; do
      case "${merge_tool}" in
      ""|" ")
          _stage_file "$file" "$review" || return 1
        ;;
      *)
        _stage_file_with_mergetool "$file" "$merge_tool" || {
          echo "Error: Failed to stage $file"
          return 1
        }
        ;;
      esac
    done

    if [ "$review" = true ]; then
      # clear
      sleep 1
    fi
    
    # Commit changes with appropriate cleanup
    _commit_changes "$message" "$review"
  }) || exit 1
}

# Function for interactive review and commit (wrapper for backward compatibility)
review_stage_and_commit_files() {
  stage_and_commit_files "$1" true "${@:2}"
}

# Perform merge operation
perform_merge() {
  local review_branch="$1"
  local origin_branch="$2"
  local merge_successful=false
  
  if [ -z "$origin_branch" ]; then
    echo "Error: Could not determine origin branch"
    exit 1
  fi

  git_in_project git checkout "$origin_branch" || {
    echo "Error: Failed to checkout $origin_branch branch"
    exit 1
  }
  
  # Merge changes
  git_in_project git merge --no-commit --no-ff "$review_branch" 

  # Review merge conflicts
  if ! git_in_project git diff --cached; then
    configure_merge_tool
    (cd "$PROJECT_DIR" && git mergetool --no-commit) &
    wait $!

    # Review merged changes
    git_in_project git diff --cached

    read -rp "Proceed with merge commit? (y/n): " proceed
    if [[ $proceed == "y" ]]; then
      git_in_project git commit && merge_successful=true
    else
      git_in_project git merge --abort
    fi
  else
    git_in_project git commit && merge_successful=true
  fi

  git_in_project git clean -f
  
  # Delete review branch if merge was successful
  if [ "$merge_successful" = true ]; then
    echo "Cleaning up review branch: $review_branch"
    git_in_project git branch -D "$review_branch" || {
      echo "Warning: Failed to delete review branch $review_branch"
    }
    echo "Project updated and review branch cleaned up successfully"
  else
    echo "Merge was not completed, review branch $review_branch retained"
  fi
}
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
  local abs_dir, parent_dir
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

# Check if working tree is clean
check_working_tree_clean() {
  if ! git_in_project git diff-index --quiet HEAD --; then
    echo "Error: You have unsaved changes. Please commit or stash them before updating."
    exit 1
  fi
}

# Create a new review branch
create_review_branch() {
  local current_review new_review branch_name
  current_review=$(git_in_project git branch | grep -c "review-patch/")
  new_review=$((current_review + 1))
  branch_name="review-patch/$new_review"
  
  git_in_project git checkout -b "$branch_name" || {
    echo "Error: Failed to create new review branch"
    exit 1
  }
  echo "$branch_name"
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
  local tools=()
  local choice
  local tool
  
  # Clear any pending input
  # shellcheck disable=SC2162
  read -t 0.1 -n 10000 || true
  
  # Collect tools first
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+Use ]]; then
      tool="${BASH_REMATCH[1]}"
      # shellcheck disable=SC2143
      if ! [[ $(echo "$line" | grep "requires a graphical session") ]]; then
        tools+=("$tool")
      fi
    fi
  done < <(git mergetool --tool-help | sed -n '/may be set to one of the following:/,/The following tools are valid, but not currently available:/p')

  # Add VS Code if available
  if command -v code >/dev/null 2>&1; then
    tools+=("code")
  fi

  # Print menu and get choice
  {
    echo "Available merge options:"
    for i in "${!tools[@]}"; do
      echo "$((i+1)). ${tools[i]}"
    done
    echo "$((${#tools[@]}+1)). Use git add -p (default)"
    echo -n "Choose a merge option (1-$((${#tools[@]}+1))): "
  } > /dev/tty

  # Read from /dev/tty explicitly
  read -r choice < /dev/tty

  # Force output buffer flush
  if [ "$choice" -le "${#tools[@]}" ] && [ "$choice" -ge 1 ]; then
    printf '%s' "${tools[$((choice-1))]}"
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
    # Create temporary files
    git show :"$relative_file_path" > "$relative_file_path.from_index"
    
    # Set up merge tool command based on tool
    local merge_cmd
    case "$tool" in
      "code")
        merge_cmd="code --wait --diff \"$relative_file_path.from_index\" \"$relative_file_path\""
        ;;
      *)
        merge_cmd="git mergetool --tool=$tool -y \"$relative_file_path\""
        ;;
    esac
    
    # Execute merge
    echo "Launching $tool for '$relative_file_path'."
    eval "$merge_cmd"
    status=$?
    
    if [ $status -eq 0 ]; then
      # Backup working tree version
      cp "$relative_file_path" "$relative_file_path.working_tree"
      
      # Stage the changes
      git add "$relative_file_path"
      
      # Restore working tree version
      mv "$relative_file_path.working_tree" "$relative_file_path"
    fi
    
    # Cleanup
    rm -f "$relative_file_path.from_index"
    rm -f "$relative_file_path.working_tree"
    
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

# Main function to stage and commit files with options
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
      #  "")
        # if [ "$review" = true ]; then
          # echo "going for - git add -p"
          # 
        # fi
        # _stage_file "$file" "$review" || return 1
        # ;;
      # "code"|"vimdiff"|"emerge"|"opendiff"|"vimdiff1"|"vimdiff2"|"vimdiff3")
          # echo "going to open MERGE TOOL $merge_tool"
      # 
        # ;;
      # *)
        # echo "Invalid merge tool selection: '$merge_tool'"
      # 
        # ;;

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
  
  git_in_project git checkout main || {
    echo "Error: Failed to checkout main branch"
    exit 1
  }
  # Merge changes
  git_in_project git checkout main
  git_in_project git merge --no-commit --no-ff "$review_branch" 

  # Review merge conflicts
  if ! git_in_project git diff --cached; then
    configure_merge_tool
    (cd "$PROJECT_DIR" && git mergetool --no-commit) &
    wait $!

    # Review merged changes
    git_in_project git diff --cached

    read -rp "Proceed with merge commit? (y/n): " proceed
    [[ $proceed == "y" ]] && git_in_project git commit || git_in_project git merge --abort
  else
    git_in_project git commit
  fi

  git_in_project git clean -f
  echo "Project updated successfully"
}
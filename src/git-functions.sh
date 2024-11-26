#!/bin/bash

#
# Copyright 2024 Sourav Ray
#
# Git utility functions for c2p.sh
#

# Store the project directory for Git operations
PROJECT_DIR=""

# Declare review options
ADD_NEW="auto-add-new"
SKIP_NEW="auto-skip-new"
# Review branch prfix
REVIEW_PREFIX="review-branch"

# Resolve the actual path of the script, even if it's a symlink
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do # Resolve symbolic links
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE" # If the link is relative, resolve it
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/console-functions.sh" || {
  echo "Error: Failed to load logging functions"
  exit 1
}

# Set the project directory for Git operations
set_project_dir() {
  # Resolve the absolute path
  PROJECT_DIR="$(cd "$1" 2>/dev/null && pwd)" || {
      print_fn_log "Error" "Failed to resolve project directory: $1"
    return 1
  }
  print_fn_log "Info" "Set project directory to: $PROJECT_DIR"
  export PROJECT_DIR
}

# Run git command in project directory
git_in_project() {
  local check_flag=$1
  case "$check_flag" in
  --stdall)
    shift
    (cd "$PROJECT_DIR" && git "$@")   # This is intended to be used for debugging purpose 
  ;;
  --stdout)
    shift
    (cd "$PROJECT_DIR" && git "$@") 2>/dev/null
  ;;
  *)
    (cd "$PROJECT_DIR" && git "$@") &>/dev/null
  ;;
  esac
}

# Initialize a new Git repository
init_git_repo() {
  git_in_project init "$PROJECT_DIR" || {
    echo "Error: Failed to initialize Git repository"
    return 1
  }
  return 0
}

# Check if there is detached HEAD
check_detached_head() {
  if git_in_project --stdout rev-parse --abbrev-ref HEAD | grep -q "HEAD"; then
    print_fn_log "Error" "HEAD is detached. Please checkout a branch before proceeding"
    return 1
  fi
  return 0
}

# Check if cureent branch isa review branch
check_if_on_a_workibg_branch() {
  # shellcheck disable=SC2046
  if [ "$(git_in_project --stdout rev-parse --abbrev-ref HEAD | grep -c "$REVIEW_PREFIX/[0-9]\+$")" -gt 0 ] ; then
    print_fn_log "Error" "You are currently on a review branch. Please move to a clean working branch and try again"
    return 1
  fi
  return 0
}

# Check if working tree is clean
check_working_tree_clean() {
  if ! git_in_project diff-index --quiet HEAD --; then
    print_fn_log "Error" "You have unsaved changes. Please commit or stash them before updating."
    return 1
  fi
  return 0
}

# Get latest unreolved review branch version
get_latest_review_branch_no() {
  local current_review_number
  current_review_number=$(git_in_project --stdout branch | \
    grep -i "^[[:space:]]*$REVIEW_PREFIX/[0-9]\+$" | \
    sed -E "s/.*$REVIEW_PREFIX\/([0-9]+).*/\1/i" | \
    head -n 1 ) # Branches don't reqire sorting

  # If no previous reviews found or invalid output, start from 0
  if ! [[ "$current_review_number" =~ ^[0-9]+$ ]]; then
    current_review_number=0
  fi
    
  echo "$current_review_number"
}

# Get latest review branch version from logs
get_lastest_review_log_no() {
  local current_review_number
  current_review_number=$(git_in_project --stdout log --all --grep="$REVIEW_PREFIX/" --pretty=format:"%s" -i | \
    grep -i "$REVIEW_PREFIX/[0-9]\+" | \
    sed -E "s/.*$REVIEW_PREFIX\/([0-9]+).*/\1/i" | \
    sort -n | \
    tail -n 1) # Log does not guarantee sequence
  
  # If no previous reviews found or invalid output, start from 0
  if ! [[ "$current_review_number" =~ ^[0-9]+$ ]]; then
    current_review_number=0
  fi

  echo "$current_review_number"
}

# Create a new review branch
create_review_branch() {
  local new_review origin_branch review_branch
  local review_from_branch review_from_log

  review_from_branch=$(get_latest_review_branch_no) 
  review_from_log=$(get_lastest_review_log_no)
  #To avoid generating any conficting branch name
  if [ "$review_from_branch" -gt "$review_from_log" ]; then
    new_review=$((review_from_branch + 1))
  else
    new_review=$((review_from_log + 1))
  fi
  review_branch="$REVIEW_PREFIX/$new_review"

  # Store the current branch name
  origin_branch=$(git_in_project --stdout rev-parse --abbrev-ref HEAD)
  if [ -z "$origin_branch" ]; then
    print_fn_log "Error" "Failed to get current branch name"
    return 1
  fi

  git_in_project checkout -b "$review_branch" || {
    print_fn_log "Error" "Failed to create new review branch"
    return 1
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
  
  git_in_project config merge.tool "$tool"
  git_in_project config mergetool.prompt false
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
  read -rt 0.1 -n 10000 2>/dev/null|| true

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
  done < <(git_in_project --stdout mergetool --tool-help | sed -n '/may be set to one of the following:/,/The following tools are valid, but not currently available:/p')
  # Print menu and get choice
  {
    clear
    print_fn_heading "Notify" "Available review tools options:"
    for i in "${!available_tools[@]}"; do
      echo "$((i+1)). ${available_tools[i]}"
    done
    echo "$((${#available_tools[@]}+1)). Standard git diff (default)"
    echo -n "Choose a review tools option (1-$((${#available_tools[@]}+1))): "
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
  local option="$1"
  local file="$2"
  local tool="$3"
  local add_new=false skip_new=false
  local relative_file_path repo_toplevel status
  relative_file_path="$(_get_relative_path "$file")"
  if [ ! -f "$relative_file_path" ]; then
    print_fn_log "Warning" "File not found: $relative_file_path"
    return 0
  fi
  
  print_fn_heading "Review and staging changes in: $relative_file_path"

  repo_toplevel=$(git_in_project --stdout rev-parse --show-toplevel)
  (cd "$repo_toplevel" && {
    git_in_project ls-files --error-unmatch "$relative_file_path" || {
      if [ "$option" == "$ADD_NEW" ]; then
        add_new=true
      elif [ "$option" == "$SKIP_NEW" ]; then
        skip_new=true
      else 
        review=false
        read -rp "Do you want to add new file - $relative_file_path? (y/n): " proceed
        if [[ $proceed = "y" ]]; then
          add_new=true
        else
          skip_new=true
        fi
      fi
    }
    
    if [ "$add_new" = true ]; then
        git_in_project add "$relative_file_path" || {
          print_fn_log "Error" "Failed to stage $relative_file_path"
          sleep 0.5
          clear
          return 1
        }
        
        print_fn_log "Info" "$relative_file_path is added to staging"
    elif [ "$skip_new" = true ]; then
        print_fn_log "Warning" "Skipping $relative_file_path!"
    else 
      # Create temporary files with meaningful names
      local index_file="$relative_file_path.from_index"
      # local merged_file="$relative_file_path.to_add" # If support kdiff3 or similar tools in future
      local backup_file="$relative_file_path.working_tree"
      
      # Get the version from index
      git_in_project --stdout show :"$relative_file_path" > "$index_file"

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
          print_fn_log "Error" "Unsupported merge tool '$tool'"
          rm -f "$index_file"
          return 1
          ;;
      esac
      
      # Execute merge
      print_fn_log "Info" "Launching $tool for '$relative_file_path'. \n Save and close the file to stage!"

      # For tools that handle waiting themselves
      eval "$merge_cmd"
      status=$?
      
      if [ $status -eq 0 ]; then
        # Backup working tree version
        cp "$relative_file_path" "$backup_file"
        
        # Stage the changes
        git_in_project add "$relative_file_path" || {
          print_fn_log "Error" "Failed to stage $relative_file_path"
          sleep 0.5
          clear
          return 1
        }
        print_fn_log "Info" "$relative_file_path is added to staging"
        # Restore working tree version
        mv "$backup_file" "$relative_file_path"
      else
        return $status
      fi
      
      # Cleanup
      rm -f "$index_file"
      rm -f "$backup_file"
    fi
    sleep 0.5
    clear
    return 0
  })
}

# Helper function to stage a single file
_stage_file() {
  local option="$1"
  local file="$2"
  local review="$3"
  local relative_path
  local add_new=true
  
  relative_path="$(_get_relative_path "$file")"
  if [ ! -f "$relative_path" ]; then
    print_fn_log "Warning" "File not found: $relative_path"
    # Ignoring bad file reference
    return 0
  fi

  print_fn_heading "Review and staging changes in: $relative_path"

  repo_toplevel=$(git_in_project --stdout rev-parse --show-toplevel)
  
  (cd "$repo_toplevel" && {
    if [ "$review" = true ]; then 
      # Check if the file is untracked
      git_in_project ls-files --error-unmatch "$relative_path" || {
        if [ "$option" == "$ADD_NEW" ]; then
          review=false
          add_new=true
        elif [ "$option" == "$SKIP_NEW" ]; then
          review=false
          add_new=false
          print_fn_log "Warning" "Skipping $relative_path!"
        else 
          review=false
          read -rp "Do you want to add new file - $relative_path? (y/n): " proceed
          if [[ $proceed = "y" ]]; then
            add_new=true
          else
            add_new=false
            print_fn_log "Warning" "Skipping $relative_path!"
          fi
        fi
      }
    fi
  
    if [ "$review" = true ]; then
      git_in_project --stdout add -p "$relative_path" || {
        print_fn_log "Error" "Failed to stage $relative_path"
        sleep 0.5
        clear
        return 1
      }
      print_fn_log "Info" "Changes in $relative_path are staged"
    elif [ "$add_new" = true ]; then
      git_in_project add "$relative_path" || {
        print_fn_log "Error" "Failed to stage $relative_path"
        sleep 0.5
        clear
        return 1
      }
      print_fn_log "Info" "$relative_path is added to staging"
    fi
  
    sleep 0.5
    clear
    return 0
  })
}

# Helper function to handle commit
_commit_changes() {
  local message="$1"
  local discard_unstaged="$2"

  local taged_file_count
  taged_file_count=$(git_in_project --stdout diff --name-only --cached  | wc -l)
  
  if [ "$taged_file_count" -gt 0 ]; then
    print_fn_heading "Committing changes with message: $message"
    git_in_project commit -m "$message" || {
      print_fn_log "Error" "Failed to commit changes"
      return 1
    }
  else
    print_fn_heading "Notify" "There is nothing to commit"
  fi

  if [ "$discard_unstaged" = true ]; then
    git_in_project restore . || {
      print_fn_log "Warning" "Failed to clean unstaged changes"
    }
  fi

  return 0
}

 # Helper function to get the list of files to be stagged
_get_files_to_stage() {
  local IFS=$'\n'
  local files=("$@")
  local modified_files temp_untracked_files untracked_files all_files

  # Get tracked files that are modified but not staged
  # shellcheck disable=SC2207
  modified_files=($(git_in_project --stdout diff --name-only))

  # Get all untracked files temporarily
  # shellcheck disable=SC2207
  temp_untracked_files=($(git_in_project --stdout ls-files --others --exclude-standard))

  # Filter untracked files based on updated files list
  untracked_files=()
  for file in "${temp_untracked_files[@]}"; do
    local abs_file
    if [[ "$file" = /* ]]; then
      # If absolute path
      abs_file="$file"
    else
      # If already relative
      abs_file="$PROJECT_DIR/$file"
    fi
    #If file is in the updated files list
    for tracked_file in "${files[@]}"; do
      if [[ "$tracked_file" == "$abs_file" ]]; then
        untracked_files+=("$file")
        break
      fi
    done
  done

  # Combine into all_files array
  all_files=("${modified_files[@]}" "${untracked_files[@]}")

  # Return the total count of files
  echo "${all_files[@]}"
}

# Function to stage and commit files with options
stage_and_commit_files() {
  local message="$1"
  local option="$2"
  local review=${3:-false}  # Optional parameter for review mode
  shift
  local files=("$@")
  local merge_tool
  print_fn_heading "Notify" "Option is : $option"
  print_fn_heading "Staging files in: $PROJECT_DIR"
  
  if [ "$review" = true ]; then
    # Get user's preferred merge tool
    merge_tool=$(_get_available_tools)
    merge_tool="$(echo "$merge_tool" | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | tr -d '[:space:]')"
  fi

  # shellcheck disable=SC2207
  local staging_candidates=($(_get_files_to_stage "${files[@]}"))

  # Change to project directory
  (cd "$PROJECT_DIR" && {
    # Stage each file
    for file in "${staging_candidates[@]}"; do
      case "${merge_tool}" in
      ""|" ")
          _stage_file "$option" "$file" "$review" || return 1
        ;;
      *)
        _stage_file_with_mergetool "$option" "$file" "$merge_tool" || {
          print_fn_log "Error" "Failed to stage $file"
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
    _commit_changes "$message" "$review" || return 1
  }) || return 1

  return 0
}

# Function for interactive review and commit
review_stage_and_commit_files() {
  stage_and_commit_files "$1" "$2" true "${@:3}"  || return 1
  return 0
}

# Perform merge operation
perform_merge() {
  local review_branch="$1"
  local origin_branch="$2"
  local merge_successful=false
  
  print_fn_heading "Notify" "Merging \"$review_branch\" changes to \"$origin_branch\"..."

  if [ -z "$origin_branch" ]; then
    print_fn_log "Error" "Could not determine origin branch"
    return 1
  fi

  git_in_project checkout "$origin_branch" || {
    print_fn_log "Error" "Failed to checkout $origin_branch branch"
    return 1
  }
  
  # Merge changes
  git_in_project merge --no-commit --no-ff "$review_branch" 

  # Review merge conflicts
  if ! git_in_project --stdout diff --cached; then
    configure_merge_tool
    if ! git_in_project mergetool; then
      print_fn_log "Error" "Git mergetool --no-commit failed. Check for conflicts or tool configuration"
      return 1
    fi

    # Review merged changes
    git_in_project --stdout diff --cached

    read -rp "Proceed with merge commit? (y/n): " proceed
    if [[ $proceed == "y" ]]; then
      if git_in_project commit; then
          merge_successful=true
        else
          print_fn_log "Error" "Failed to commit merge"
          return 1
        fi
    else
      git_in_project merge --abort
      return 1
    fi
  else
    local commitMessage="Merged from $review_branch"
    if _commit_changes "$commitMessage" true; then
        merge_successful=true
    else
      print_fn_log "Error" "Failed to commit merge"
      return 1
    fi
  fi

  if [ "$merge_successful" = true ]; then
    print_fn_log "Info" "Merge completed"
    return 0
  else
    print_fn_log "Error" "Merge was not completed"
    return 1
  fi
}

# Delete review branch
delete_review_branch() {
  local review_branch="$1"
  if [ -n "$review_branch" ] && git_in_project rev-parse --verify "$review_branch"; then
    git_in_project branch -D "$review_branch" || {
      print_fn_log "Warning" "Review branch $review_branch, could not be deleted"
      return 1
    }
  fi
  return 0
}

# Cleanup function to restore git state
cleanup_git_state() {
  local review_branch="$1"
  local origin_branch="$2"

  print_fn_heading "Notify" "Performing git state cleanup..."
  
  # Check if we're in a git repository
  if ! git_in_project rev-parse --git-dir; then
    print_fn_log "Warning" "Not in a git repository, skipping cleanup"
    print_fn_heading "Alert" "Cleanup aborted"
    return 1
  fi

  # Get current branch name
  local current_branch
  current_branch=$(git_in_project --stdout rev-parse --abbrev-ref HEAD)

  # If we're in the middle of a merge, abort it
  if [ -f "$PROJECT_DIR/.git/MERGE_HEAD" ]; then
    print_fn_log "Warning" "Aborting incomplete merge..."
    git_in_project merge --abort || {
      print_fn_log "Error" "Failed to abort merge. The repository remains in a conflicted state"
      print_fn_heading "Alert" "Your local repository is untidy; manual cleanup required"
      return 1
    }
    print_fn_heading "Merge successfully aborted. The repository is back to its pre-merge state"
  fi

  # Reset any staged and unstaged changes
  print_fn_log "info" "Preparing to discard uncommited changes from $current_branch..."
  git_in_project reset --quiet || {
    print_fn_log "Warning" "Git reset failed. Staged changes remain in your directory"
  }
  git_in_project restore . || {
    print_fn_log "Warning" "Git restore failed. Umstaged changes remain in your directory"
  }

  # Clean untracked files and directories
  print_fn_log "info" "Preparing to discard untracked changes changes..."
  git_in_project clean -fd --quiet || {
    print_fn_log "Warning" "Git clean failed. Untracked files and directories remain in your workspace"
  }

  # Restore original branch if we're on review branch
  if [ -n "$origin_branch" ] && [ "$current_branch" != "$origin_branch" ]; then
    print_fn_log "Info" "Restoring original branch: $origin_branch"
    if git_in_project checkout "$origin_branch"; then
      print_fn_heading "Switched to: $origin_branch"
      # Delete review branch if it exists
      if ! delete_review_branch "$review_branch"; then
        print_fn_log "Warning" "Project cleaned, but review branch retained"
      else
        print_fn_log "Info" "Project cleaned and review branch deleted successfully"
      fi
      
    else
      print_fn_log "Warning"  "Failed to restore original branch"
      print_fn_heading "Alert" "Updates committed to the review branch. Manual intervention required to proceed."
      return 0
    fi
  elif [ "$current_branch" == "$origin_branch" ]; then # After a successful merge 
    # Delete review branch if it exists
    if ! delete_review_branch "$review_branch"; then
      print_fn_log "Warning" "Project updated and cleaned, review branch retained.d"
    else
      print_fn_log "Info" "Project updated, cleaned, and review branch deleted"
    fi
  fi
  print_fn_heading "Notify" "Cleanup completed"

  return 0
}
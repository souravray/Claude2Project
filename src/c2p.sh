#!/bin/bash

#
# Copyright 2024 Sourav Ray
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions, and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions, and the following disclaimer in the documentation or other materials provided with the distribution.
#
#
# DISCLAIMER:
# This code converts Standard Claude.ai multifile project output into a structured code in seconds.
# This program is not affiliated with Claude.ai, and the author is not responsible for any future changes 
# in Claude.ai output or the compatibility of this program with future format.
#

# Resolve the actual path of the script, even if it's a symlink
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do # Resolve symbolic links
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE" # If the link is relative, resolve it
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/git-functions.sh" || {
  echo "Error: Failed to load git functions"
  exit 1
}

# Get absolute path of a directory
get_absolute_path() {
  local dir="$1"
  local abs_dir

  if [ -d "$dir" ]; then
      abs_dir="$(cd "$dir" && pwd)"
  else
    local parent_dir
    # If directory doesn't exist, get absolute path of parent and append dir name
    parent_dir="$(cd "$(dirname "$dir")" && pwd)"
    abs_dir="${parent_dir}/$(basename "$dir")"
    # Create the directory
    mkdir -p "$abs_dir" || { 
      print_fn_log "Error" "Failed to create directory: $abs_dir"
      return 1
    }
  fi
  echo "$abs_dir"
}

# Global arrays to hold file paths and their corresponding content
file_paths=()
file_contents=()

# Trim leading and trailing spaces from a string
trim_spaces() {
  echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Create directory if not exists
directory_create() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    print_fn_log "Info" "Creating directory: $dir"
    mkdir -p "$dir" 2>/dev/null || {
      print_fn_log "Error" "Could not create directory $dir"
      return 1
    }
  fi
  return 0
}

# Write content to a file and setting permissions
write_file_content() {
  local file_path="$1"
  local file_content="$2"

# Create the file's parent directory exists before writing
  directory_create "$(dirname "$file_path")" || return 1

# Write content to the file
  save_file "$file_path" "$file_content" || return 1

# Grant 755 permission to the file
  chmod 755 "$file_path" 2>/dev/null || {
    print_fn_log "Error" "Could not set permissions for $file_path"
    return 1
  }
  return 0
}

# Save the current file's path and content
save_file() {
  local file_path="$1"
  local file_content="$2"
  if [ -o noclobber ]; then
  # If noclobber is on -> https://unix.stackexchange.com/questions/45201/bash-what-does-do/45203
    echo "$file_content" >| "$file_path" || {
      echo "$file_content" >! "$file_path" || {
        print_fn_log "Error" "Cannot overwrite the file $file_path, noclobber is on"
        return 1
      }
    }
  else
    echo "$file_content" > "$file_path" || {
      print_fn_log "Error" "Cannot write to the file $file_path, noclobber is off"
      return 1
    }
  fi 
  return 0
}

# Write files based on the map
write_files() {
  for i in "${!file_paths[@]}"; do
    local file_path="${file_paths[$i]}"
    local content="${file_contents[$i]}"
    write_file_content "$file_path" "$content" || return 1
  done
  return 0
}

# Process each line in the file, adding files and directories
process_line() {
  local line="$1" dest_dir="$2"

  if [[ "$line" =~ ^/\*$ ]]; then
    return  # Ignore comment lines
  elif [[ "$line" =~ ^//.*\..*$ ]]; then
# If a new file is specified, save the previous one and reset
    if [[ -n "$current_file_path" ]]; then
# Save the current file's content and path in arrays
      file_paths+=("$current_file_path")
      file_contents+=("$current_file_content")
    fi
    current_file_path="$dest_dir/$(trim_spaces "${line//\/\//}")"
    current_file_content=""
  else
# Append line to current file content
    current_file_content+="$line"$'\n'
  fi
}

# Parse the file structure and populate directories and files
parse_file_structure() {
  local input_file="$1" dest_dir="$2"
  current_file_content=""
  current_file_path=""

# Read the input file line by line
  while IFS= read -r line || [[ -n "$line" ]]; do
    process_line "$line" "$dest_dir"
  done < "$input_file"

# Save the last file after the loop if content exists
  if [[ -n "$current_file_path" ]]; then
    file_paths+=("$current_file_path")
    file_contents+=("$current_file_content")
  fi

# Write all the files
  write_files || return 1
  return 0
}

# Clean Up 
clear_directory() {
  local project_dir=$1 
  print_fn_log "Warning" "called directory cleaning for: $project_dir"
# rm -rf "$item"
  for item in "$project_dir"/.* "$project_dir"/*; do
    # Skip current directory (.) and parent directory (..)
  if [ "$(basename "$item")" == "." ] || [ "$(basename "$item")" == ".." ]; then
        continue
    fi

    # Check if item is a directory
    if [ -d "$item" ]; then
        print_fn_log "Warning" "Removing directory: $item"
        rm -rf "$item"
    elif [ -f "$item" ]; then
        print_fn_log "Warning" "Removing file: $item"
        rm -f "$item"
    fi
  done
}

# Initialize new project with a Git workflow
init_project_action() {
  local input_file="$1" dir="$2" option="$3"
  print_fn_heading "Initalizing a new project"

  if [ "$option" == "$SKIP_NEW" ]; then
      print_fn_log "Warning" "Poject cannot be initiated with --$SKIP_NEW, switching to --$ADD_NEW"
      option="$ADD_NEW"
  fi

  # Get absolute path of destination directory
  local abs_dir
  abs_dir="$(get_absolute_path "$dir")" || {
    print_fn_log "Error" "Failed to get absolute path"
    return 1
  }
  
  # Set project directory for Git operations
  set_project_dir "$abs_dir" || {
    clear_directory "$abs_dir"
    return 1
  }
  
  # Initialize Git repository first
  init_git_repo || {
    clear_directory "$abs_dir"
    return 1
  }
  
  # Parse and create files
  parse_file_structure "$input_file" "$abs_dir" || {
    clear_directory "$abs_dir"
    return 1
  }
  
  # Stage and commit all files
  stage_and_commit_files "Initial project setup" "$option" "${file_paths[@]}" || {
    clear_directory "$abs_dir"
    return 1
  }
  
  print_fn_heading "Notify" "Project initialized with Git repository"
  return 0
}

# Update existing project with Git workflow
update_project_action() {
  local input_file="$1" dir="$2" option="$3"
  local abs_dir review_branch

  # Get absolute path of destination directory
  abs_dir="$(get_absolute_path "$dir")" || {
    print_fn_log "Error" "Failed to get absolute path"
    return 1
  }

  # Set project directory for Git operations
  set_project_dir "$abs_dir" ||  return 1

  # Check if HEAD is detached
  check_detached_head ||  return 1

  #check if branch is a working branch
  check_if_on_a_workibg_branch || return 1
  
  # Check for unsaved changes
  check_working_tree_clean || return 1
  
  # Create new review branch
  # Get review and origin branch names
  branches=$(create_review_branch) || return 1
  origin_branch="${branches%%:*}"
  review_branch="${branches##*:}"
  
  # Parse and update files
  parse_file_structure "$input_file" "$abs_dir" || {
    print_fn_heading "Failure" "STOPING HERE!!"
    cleanup_git_state "$review_branch" "$origin_branch"
    return 0
  }

  # Stage and commit changes in review branch
  review_stage_and_commit_files "Update from Claude output" "$option" "${file_paths[@]}" || {
    cleanup_git_state "$review_branch" "$origin_branch" 
    return 1 
  }
  
  # Perform merge process
  perform_merge "$review_branch" "$origin_branch" || {
    cleanup_git_state "$review_branch" "$origin_branch"
    return 1 
  }
  
  # Clean up after a succesful merge
  if ! cleanup_git_state "$review_branch" "$origin_branch"; then
      print_fn_heading "Alert" "Project updated successfully. However, the repository may contain some unresolved changes."
  else
      print_fn_heading "Notify" "Project updated successfully"
  fi
  return 0
}


# Route to init_project_action or update_project_action based on directory status
action_router() {
  local input_file="$1" dir="$2" option="$3"

  # Check if the directory has a .git folder
  if [ -d "$dir/.git" ]; then
      print_fn_heading "Notify" "$dir has an Existing Git repository. Updating the project..."
      update_project_action "$input_file" "$dest_dir" "$option" || {
          print_fn_heading "Failure" "Failurer" "Update failed: Unable to complete the project update"
          return 1
      }
  else
    # Check if the directory is empty (excluding hidden files)
    if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
      print_fn_heading "Notify" "$dir is empty. Initiating new project..."
      init_project_action "$input_file" "$dest_dir" "$option" || {
        print_fn_heading "Failure" "Initialization failed: Unable to start the project"
        return 1
      }
    else
      print_fn_heading "Failure" "$dir is not empty. Cannot initiate new project. Please choose a diffrent directory"
      return 1
    fi
  fi
}

# Main script entry point
main() {
  local option=""
  if [ -z "$1" ] || [ "$1" == "--help" ]; then
    echo "Usage: c2p [--option] <input_file> [destination_directory]"
    echo -e "  --auto-add-new \t Will stage a new file during a review without giving any prompt"
    echo -e "  --auto-skip-new \t Will skip a new file during a review without giving amy prompt"
    exit 1
  elif [ "$1" == "--auto-add-new" ]; then
    option="$ADD_NEW"
    shift
  elif [ "$1" == "--auto-skip-new" ]; then
    option="$SKIP_NEW"
    shift
  elif [[ "$1" =~ ^--* ]]; then
    print_fn_log "Warning" "Unknow option $1, is ignored!"
    print_fn_heading "Notify" "Run c2p --help to learn more about options"
    shift 
  fi

  local input_file="$1"
  local dest_dir="${2:-.}"

  # Check if input file exists
  if ! [ -f "$input_file" ]; then
    print_fn_heading "Failure" "Cannot find the source file"
    exit 1
  fi

# Only create the directory if it's not the current directory
  if [[ "$dest_dir" != "." ]]; then
    directory_create "$dest_dir"
  fi
  if action_router "$input_file" "$dest_dir" "$option"; then
    print_fn_heading "Success" "Directory structure and files created successfully in $dest_dir"
  fi
}

main "$@"

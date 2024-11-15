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

# Source the git functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
      echo "Error: Failed to create directory: $abs_dir"
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
    echo "Creating directory: $dir"
    mkdir -p "$dir" || {
      echo "Error: Could not create directory $dir"
      exit 1
    }
  fi
}

# Write content to a file and setting permissions
write_file_content() {
  local file_path="$1"
  local file_content="$2"

# Create the file's parent directory exists before writing
  directory_create "$(dirname "$file_path")"

# Write content to the file
  save_file "$file_path" "$file_content"

# Grant 755 permission to the file
  chmod 755 "$file_path" || {
    echo "Error: Could not set permissions for $file_path"
    exit 1
  }
}

# Save the current file's path and content
save_file() {
  local file_path="$1"
  local file_content="$2"
  if [ -o noclobber ]; then
  # If noclobber is on -> https://unix.stackexchange.com/questions/45201/bash-what-does-do/45203
    echo "$file_content" >| "$file_path" || {
      echo "$file_content" >! "$file_path" || {
        echo "Error: Cannot overwrite the file $file_path, noclobber is on"
        exit 1
      }
    }
  else
    echo "$file_content" > "$file_path" || {
      echo "Error: Cannot write to the file $file_path, noclobber is off"
      exit 1
    }
  fi 
}

# Write files based on the map
write_files() {
  for i in "${!file_paths[@]}"; do
    local file_path="${file_paths[$i]}"
    local content="${file_contents[$i]}"
    write_file_content "$file_path" "$content"
  done
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
  write_files
}

# Initialize new project with a Git workflow
init_project_action() {
  local input_file="$1" dir="$2"
  local parent_dir
  
  # Get absolute path of destination directory
  local abs_dir
  abs_dir="$(get_absolute_path "$dir")" || {
    echo "Failed to get absolute path"
    exit 1
  }
  
  echo "Initializing project in: $abs_dir"
  
  # Initialize Git repository first
  init_git_repo "$abs_dir"
  
  # Parse and create files
  parse_file_structure "$input_file" "$abs_dir"
  
  # Stage and commit all files
  stage_and_commit_files "Initial project setup" "${file_paths[@]}"
  
  echo "Project initialized with Git repository"
}


# Update existing project with Git workflow
update_project_action() {
  local input_file="$1" dir="$2"
  local abs_dir review_branch

  # Get absolute path of destination directory
  abs_dir="$(get_absolute_path "$dir")" || {
    echo "Failed to get absolute path"
    exit 1
  }
  
  # Set project directory for Git operations
  set_project_dir "$abs_dir"
  
  # Check for unsaved changes
  check_working_tree_clean
  
  # Create new review branch
  review_branch=$(create_review_branch)
  
  # Parse and update files
  parse_file_structure "$input_file" "$abs_dir"

  # Stage and commit changes in review branch
  review_stage_and_commit_files "Update from Claude output" "${file_paths[@]}"
  
  # Perform merge process
  perform_merge "$review_branch"
  
  echo "Project updated successfully"
}


# Route to init_project_action or update_project_action based on directory status
action_router() {
  local input_file="$1" dir="$2"

  # Check if the directory has a .git folder
  if [ -d "$dir/.git" ]; then
      echo "$dir has an Existing Git repository. Updating the project..."
      update_project_action "$input_file" "$dest_dir"
  else
    # Check if the directory is empty (excluding hidden files)
    if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
      echo "$dir is empty. Initiating new projectt..."
      init_project_action "$input_file" "$dest_dir"
    else
      echo "$dir is not empty. Cannot initiate new project. Please choose a diffrent directory."
      exit 1
    fi
  fi
}

# Main script entry point
main() {
  if [ -z "$1" ]; then
    echo "Usage: $0 <input_file> [destination_directory]"
    exit 1
  fi

  local input_file="$1"
  local dest_dir="${2:-.}"

# Only create the directory if it's not the current directory
  if [[ "$dest_dir" != "." ]]; then
    directory_create "$dest_dir"
  fi
  action_router "$input_file" "$dest_dir"
  echo "Directory structure and files created successfully in $dest_dir"
}

main "$@"

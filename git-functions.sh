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
    
    # Ensure we have the absolute path
    local abs_dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        # If directory doesn't exist yet, get absolute path of parent and append dir name
        local parent_dir="$(cd "$(dirname "$dir")" 2>/dev/null && pwd)"
        abs_dir="${parent_dir}/$(basename "$dir")"
    }
    
    echo "Initializing Git repository in: $abs_dir"
    git init "$abs_dir" || {
        echo "Error: Failed to initialize Git repository"
        exit 1
    }
    set_project_dir "$abs_dir"
}

# Stage and commit files
stage_and_commit_files() {
    local message="$1"
    shift
    local files=("$@")
    
    echo "Staging files in: $PROJECT_DIR"
    
    # Change to project directory
    (cd "$PROJECT_DIR" && {
        for file in "${files[@]}"; do
            # Get the path relative to PROJECT_DIR
            local relative_path
            if [[ "$file" = /* ]]; then
                # If absolute path, make it relative to PROJECT_DIR
                relative_path="${file#$PROJECT_DIR/}"
            else
                # If already relative, use as is
                relative_path="$file"
            fi
            
            echo "Staging file: $relative_path"
            if [ -f "$relative_path" ]; then
                git add "$relative_path" || {
                    echo "Error: Failed to stage $relative_path"
                    return 1
                }
            else
                echo "Warning: File not found: $relative_path"
            fi
        done
        
        # Commit the changes
        echo "Committing changes with message: $message"
        git commit -m "$message" || {
            echo "Error: Failed to commit changes"
            return 1
        }
    }) || exit 1
}
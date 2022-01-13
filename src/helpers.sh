#!/usr/bin/env bash

# shortcut to get a value from user (stdin) or return a default value
function match_answer_or_default() {
    local QUESTION=$1
    local DEFAULT=$2

    read -r -p "$QUESTION" ANSWER

    if [[ ! -z "$ANSWER" ]]; then
        echo $ANSWER
    else
        echo $DEFAULT
    fi
}

# fetches the lastest tag version from remote repository, if project was cloned from git
function get_latest_git_tag() {
    local EXIT_ON_FAILURE=$1

    if [[ -z "$EXIT_ON_FAILURE" ]]; then
        EXIT_ON_FAILURE=1
    fi

    if [[ -d "$BASE_DIR/.git" ]]; then
        cd "$BASE_DIR"
        git fetch --tags

        local LATEST_TAG=$(git describe --tags `git rev-list --tags --max-count=1`)
        if [[ "0" != "$?" ]]; then
            print_error "Failed to check out the latest tag. Sorry..." 1
            exit 1
        fi

        echo $LATEST_TAG
    else
        # only if error shall be thrown
        if [[ "1" == "$EXIT_ON_FAILURE" ]]; then
            print_error "No .git directory is found in proxy path. Did you clone or download?"
            print_error "If you downloaded this project, this command will not work. Please download the current archive." 1
            exit 1
        fi
    fi
}

# returns the current tag from `git status`, if project was cloned from git
function get_current_git_tag() {
    local EXIT_ON_FAILURE=$1

    if [[ -z "$EXIT_ON_FAILURE" ]]; then
        EXIT_ON_FAILURE=1
    fi

    if [[ -d "$BASE_DIR/.git" ]]; then
        cd "$BASE_DIR"

        local LATEST_LOG=$(git log --decorate -1)
        if [[ "0" != "$?" ]]; then
            print_error "Failed to check the current state of repository. Sorry..." 1
            exit 1
        fi

        # if the repository is situated on a branch
        if [[ ! -z `echo $LATEST_LOG | grep "HEAD -> "` ]]; then
            local CURRENT_BRANCH=`echo $LATEST_LOG | grep "HEAD -> " | sed -e 's/.*HEAD -> //' | sed -e 's/).*//' | sed -e 's/,.*//'`
            echo $CURRENT_BRANCH
            echo "BRANCH"

        # else a tag should be checked out
        elif [[ ! -z `echo $LATEST_LOG | grep "HEAD, tag: "` ]]; then
            local CURRENT_TAG=`echo $LATEST_LOG | grep "HEAD, tag: " | sed -e 's/.*HEAD, tag: //' | sed -e 's/).*//' | sed -e 's/,.*//'`
            echo $CURRENT_TAG
            echo "TAG"
        fi
    else
        # only if error shall be thrown
        if [[ "1" == "$EXIT_ON_FAILURE" ]]; then
            print_error "No .git directory is found in proxy path. Did you clone or download?"
            print_error "If you downloaded this project, this command will not work. Please download the current archive." 1
            exit 1
        fi
    fi
}

# compare current branch/tag with latest remote branch and output a warning, if not matching
function check_for_updates() {
    local UPD_FILE_NAME=".last-update"
    local UPD_FILE_PATH="$BASE_DIR/$UPD_FILE_NAME"

    if [[ ! -f "$UPD_FILE_PATH" ]]; then
        touch "$UPD_FILE_PATH"
    fi

    local TODAY=`date +"%Y-%m-%d"`
    local TODAY_MINUS_ONE_WEEK=`date +"%Y-%m-%d" -d "1 week ago"`
    local LAST_UPDATE=`cat $UPD_FILE_PATH`

    if [[ -z "$LAST_UPDATE" || "$LAST_UPDATE" < "$TODAY_MINUS_ONE_WEEK" ]]; then
        local CURRENT_TAG_RESULT=`get_current_git_tag 0`
        local SPLIT_TAG_RESULT=(${CURRENT_TAG_RESULT%$'\n'})
        local LATEST_TAG=`get_latest_git_tag 0`
        local CURRENT_TAG=${SPLIT_TAG_RESULT[0]}
        local BRANCH_TYPE=${SPLIT_TAG_RESULT[1]}

        if [[ "$CURRENT_TAG" != "$LATEST_TAG" ]]; then
            if [[ "BRANCH" == "$BRANCH_TYPE" ]]; then
                print_warning "You have currently checked out the branch '$CURRENT_TAG', which is not recommended!"
            else
                print_warning "You have currently checked out the tag '$CURRENT_TAG', which is outdated!"
            fi
            print_warning "Please use 'DockerExec self-update' to switch to the latest version." 1
        fi

        echo "$TODAY" > $UPD_FILE_PATH
    fi
}

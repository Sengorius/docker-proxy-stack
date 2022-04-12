#!/usr/bin/env bash

# shortcut to get a value from user (stdin) or return a default value
function match_answer_or_default() {
    local QUESTION=$1
    local DEFAULT=$2

    read -r -p "$QUESTION" ANSWER

    if [[ -n "$ANSWER" ]]; then
        echo "$ANSWER"
    else
        echo "$DEFAULT"
    fi
}

# fetches the lastest tag version from remote repository, if project was cloned from git
function get_latest_git_tag() {
    local EXIT_ON_FAILURE=$1

    if [[ -z "$EXIT_ON_FAILURE" ]]; then
        EXIT_ON_FAILURE=1
    fi

    if [[ -d "$BASE_DIR/.git" ]]; then
        cd "$BASE_DIR" || (print_error "Could not change directory to $BASE_DIR" && exit 1)
        git fetch --tags

        local LATEST_TAG
        if ! LATEST_TAG=$(git describe --tags "$(git rev-list --tags --max-count=1)"); then
            print_error "Failed to check out the latest tag. Sorry..." 1
            exit 1
        fi

        echo "$LATEST_TAG"
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
        cd "$BASE_DIR" || (print_error "Could not change directory to $BASE_DIR" && exit 1)

        local LATEST_LOG
        if ! LATEST_LOG=$(git log --decorate -1); then
            print_error "Failed to check the current state of repository. Sorry..." 1
            exit 1
        fi

        # if the repository is situated on a branch
        if echo "$LATEST_LOG" | grep -q "HEAD -> "; then
            local CURRENT_BRANCH
            CURRENT_BRANCH=$(echo "$LATEST_LOG" | grep "HEAD -> " | sed -e 's/.*HEAD -> //' | sed -e 's/).*//' | sed -e 's/,.*//')

            echo "$CURRENT_BRANCH"
            echo "BRANCH"

        # else a tag should be checked out
        elif echo "$LATEST_LOG" | grep -q "HEAD, tag: "; then
            local CURRENT_TAG
            CURRENT_TAG=$(echo "$LATEST_LOG" | grep "HEAD, tag: " | sed -e 's/.*HEAD, tag: //' | sed -e 's/).*//' | sed -e 's/,.*//')

            echo "$CURRENT_TAG"
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
    if [[ ! -f "$UPD_FILE_PATH" ]]; then
        touch "$UPD_FILE_PATH"
    fi

    local TODAY
    TODAY=$(date +"%Y-%m-%d")

    local TODAY_MINUS_ONE_WEEK
    TODAY_MINUS_ONE_WEEK=$(date +"%Y-%m-%d" -d "1 week ago")

    local LAST_UPDATE
    LAST_UPDATE=$(cat "$UPD_FILE_PATH")

    if [[ -z "$LAST_UPDATE" || "$LAST_UPDATE" < "$TODAY_MINUS_ONE_WEEK" ]]; then
        local CURRENT_TAG_RESULT
        CURRENT_TAG_RESULT=$(get_current_git_tag 0)

        local SPLIT_TAG_RESULT
        SPLIT_TAG_RESULT=(${CURRENT_TAG_RESULT%$'\n'})

        local LATEST_TAG
        LATEST_TAG=$(get_latest_git_tag 0)

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

        echo "$TODAY" > "$UPD_FILE_PATH"
    fi
}

# asking question to import a .sql file dump into a database container
function import_to_database_container() {
    print_info "Starting the import for a database dump. Please position the .sql file within the data"
    print_info "directory in proxy-stack and map the volume in your database containers with"
    print_info "\`--volume \"\${DATA_PATH}:/var/data\"\` to make this work." 1
    print_info "Then answer following questions:" 1

    CONTAINER_NAME=$(match_answer_or_default "Which running container should be used? " "")
    if [[ -z "$CONTAINER_NAME" ]]; then
        print_error "The container name is a mandatory parameter!" 1
        exit 1
    fi

    RUNNING_APP=$(docker ps -aq -f name="$CONTAINER_NAME" -f status="running")
    if [[ -z "$RUNNING_APP" ]]; then
        print_error "The container $CONTAINER_NAME is not up and running!" 1
        exit 1
    fi

    DB_ARCH=$(match_answer_or_default "Which database architecture is on that container? [MYSQL/pgsql] " "mysql")
    if [[ -z "$DB_ARCH" ]]; then
        print_error "The database architecture is a mandatory parameter!" 1
        exit 1
    fi

    case "$DB_ARCH" in
        mysql|MYSQL|pgsql|PGSQL)
            # anything is fine
            ;;
        *)
            print_error "Unknown database architecture '$DB_ARCH'!" 1
            exit 1
            ;;
    esac

    DB_NAME=$(match_answer_or_default "Which database on that container shall be imported in? " "")
    if [[ -z "$DB_NAME" ]]; then
        print_error "The database name is a mandatory parameter!" 1
        exit 1
    fi

    FILE_NAME=$(match_answer_or_default "Which file shall be imported? " "")
    if [[ -z "$FILE_NAME" ]]; then
        print_error "Please specify the dump .sql file to import!" 1
        exit 1
    fi

    case "$DB_ARCH" in
        MYSQL|mysql)
            COMMAND="mysql -proot -e 'CREATE DATABASE IF NOT EXISTS $DB_NAME' && mysql -proot '$DB_NAME' < '/var/data/$FILE_NAME'"
            ;;
        PGSQL|pgsql)
            COMMAND="echo \"SELECT 'CREATE DATABASE $DB_NAME' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec\" | psql && psql -d '$DB_NAME' < '/var/data/$FILE_NAME'"
            ;;
    esac

    echo
    docker exec -it "$CONTAINER_NAME" bash -c "$COMMAND" && \
    print_info "Import complete." 1
}

#!/usr/bin/env bash

# offer a function to print found hosts as a list
# and also include into the hosts file, if not done yet
function print_hosts() {
    local COMPOSE=$1

    local HOSTS
    HOSTS=$(grep "VIRTUAL_HOST" "$COMPOSE")

    if [[ -n "$HOSTS" ]]; then
        print_info "Following hosts have been booted:"
        echo "$HOSTS" | while read -r line; do
            [[ "$line" =~ VIRTUAL_HOST.[[:space:]]*(.*)$ ]]

            if [[ -n "$line" && -n "${BASH_REMATCH[1]}" ]]; then
                publish_single_entry_hosts_file "${BASH_REMATCH[1]}"
                echo "  https://${BASH_REMATCH[1]}"
            fi
        done
    fi
}

# append host to hosts file, if not yet included
function publish_single_entry_hosts_file() {
    local ENTRY=$1

    local HOSTS_HAS_FILE
    HOSTS_HAS_FILE=$(grep -Ei "^127.0.0.1\s+$ENTRY" "$LINUX_HOSTS")

    if [[ -f "$LINUX_HOSTS" && -z "$HOSTS_HAS_FILE" ]]; then
        sudo true # sudo must be given
        echo "127.0.0.1    $ENTRY" | sudo tee -a "$LINUX_HOSTS" > /dev/null 2>&1
        print_info "'127.0.0.1 $ENTRY' was added to your hosts file"
    fi
}

# get the defined $_CONTAINER_SUFFIXES from proxy .env file or return a default
function get_container_suffixes() {
    local TYPE=$1

    local SUFFIXES
    SUFFIXES="${TYPE}_CONTAINER_SUFFIXES"
    SUFFIXES="${!SUFFIXES}"

    if [[ -z "$SUFFIXES" ]]; then
        if [[ "WEB" == "$TYPE" || "web" == "$TYPE" ]]; then
            SUFFIXES="web"
        elif [[ "APP" == "$TYPE" || "app" == "$TYPE" ]]; then
            SUFFIXES="app|php"
        else
            print_error "Unknown container suffix type '$TYPE'!" 1
            exit 1
        fi
    fi

    echo "$SUFFIXES"
}

# offer a function that tries to find the current -app container name
function get_container_names() {
    local ENV_FILE=$1

    local APP_PREFIX
    APP_PREFIX=$(grep "^CON_PREFIX=" "$ENV_FILE" | sed -e 's/^CON_PREFIX=//' | sed -e 's/[[:space:]]*$//')

    local APP_NAME
    APP_NAME=$(grep "^CON_NAME=" "$ENV_FILE" | sed -e 's/^CON_NAME=//' | sed -e 's/[[:space:]]*$//')

    local ACF
    ACF=$(get_container_suffixes "APP")

    if [[ -n "$APP_PREFIX" ]]; then
        local RUNNING_APPS=
        RUNNING_APPS=$(docker ps -aq -f name="^$APP_PREFIX((?:-|_).+)*(-|_)($ACF)$" -f status="running")
        echo "$RUNNING_APPS"

    elif [[ -n "$APP_NAME" ]]; then
        echo "$APP_NAME"
    else
        echo ""
    fi

    exit 0
}

# offer a function that tries to find the current -web container name
function get_nginx_names() {
    local ENV_FILE=$1

    local APP_PREFIX
    APP_PREFIX=$(grep "^CON_PREFIX=" "$ENV_FILE" | sed -e 's/^CON_PREFIX=//' | sed -e 's/[[:space:]]*$//')

    local APP_NAME
    APP_NAME=$(grep "^CON_NAME=" "$ENV_FILE" | sed -e 's/^CON_NAME=//' | sed -e 's/[[:space:]]*$//')

    local WCF
    WCF=$(get_container_suffixes "WEB")

    if [[ -n "$APP_PREFIX" ]]; then
        local RUNNING_APPS
        RUNNING_APPS=$(docker ps -aq -f name="^$APP_PREFIX((?:-|_).+)*(-|_)($WCF)$" -f status="running")
        echo "$RUNNING_APPS"

    elif [[ -n "$APP_NAME" ]]; then
        echo "$APP_NAME"
    else
        echo ""
    fi

    exit 0
}

# decide which executable to user for docker composition
function get_compose_executable() {
    command -v docker-compose > /dev/null 2>&1 && echo 'docker-compose' || echo 'docker compose'
}

# offer a function to start compose and enter bash
function compose_run() {
    local COMPOSE=$1
    local ENV_FILE=$2
    local INTERRUPT_START_CONTAINER=${INTERRUPT_START_CONTAINER:-no}

    COMPOSE_EXEC=$(get_compose_executable)

    $COMPOSE_EXEC -f "$COMPOSE" --env-file "$ENV_FILE" up -d

    if [[ -n "$ENV_FILE" ]]; then
        update_host_files "$ENV_FILE"

        local START_CONTAINER
        START_CONTAINER=$(grep "^START_CONTAINER=" "$ENV_FILE" | sed -e 's/^START_CONTAINER=//' | sed -e 's/[[:space:]]*$//')

        if [[ "no" != "$INTERRUPT_START_CONTAINER" ]]; then
            echo "Interrupting to start a shell into container."
        elif [[ -n "$START_CONTAINER" ]]; then
            if [[ "none" != "$START_CONTAINER" ]]; then
                # retry sh, if bash is not found
                docker exec -it "${START_CONTAINER}" bash || \
                docker exec -it "${START_CONTAINER}" sh
            fi
        else
            local CON_NAMES=($(get_container_names "$ENV_FILE"))

            if [[ "0" != "${#CON_NAMES[@]}" ]]; then
                # retry sh, if bash is not found
                docker exec -it "${CON_NAMES[0]}" bash || \
                docker exec -it "${CON_NAMES[0]}" sh
            fi
        fi
    fi
}

# offer a function to stop and remove all containers in a context
function compose_halt() {
    local COMPOSE=$1
    local ENV_FILE=$2

    COMPOSE_EXEC=$(get_compose_executable)

    $COMPOSE_EXEC -f "$COMPOSE" --env-file "$ENV_FILE" stop
    $COMPOSE_EXEC -f "$COMPOSE" --env-file "$ENV_FILE" rm -f
}

# starts a single spawn container by reading and importing the file itself
function start_spawn_container() {
    local FILENAME="$1"
    local SPAWN_FILE="$SPAWNS_ENABLED_PATH/$FILENAME"
    CON_NAME=$(grep "^CONTAINER_NAME=" "$SPAWN_FILE" | sed -e 's/^CONTAINER_NAME=//' | tr -d '"' | sed -e 's/[[:space:]]*$//')

    EXITED_CONTAINER=$(docker ps -aq -f name="$CON_NAME" -f status="exited")
    if [[ -n "$EXITED_CONTAINER" ]]; then
        docker start "$CON_NAME"
    else
        RUNNING_CONTAINER=$(docker ps -aq -f name="$CON_NAME")

        if [[ -z "$RUNNING_CONTAINER" ]]; then
            # shellcheck disable=SC1090
            . "$SPAWN_FILE" > /dev/null

            [[ $(grep "VIRTUAL_HOST" "$SPAWN_FILE") =~ VIRTUAL_HOST=(.*)[[:space:]] ]]
            CON_HOST=${BASH_REMATCH[1]}

            print_info "Started container $CON_NAME"
            if [[ -n "$CON_HOST" ]]; then
                publish_single_entry_hosts_file "$CON_HOST"
                echo "  https://$CON_HOST"
            fi
        fi
    fi
}

# update any running -web and -app containers /etc/hosts file with the new started IP of the current -web container
function update_host_files() {
    local ENV_FILE=$1
    local HOST_ACTION=$2
    local WEB_CON_NAMES=($(get_nginx_names "$ENV_FILE"))
    local APP_CON_NAMES=($(get_container_names "$ENV_FILE"))

    if [[ -z "$HOST_ACTION" ]]; then
        HOST_ACTION="append"
    fi

    local SHALL_BE_PUBLISHED=

    for WEB_CON in "${WEB_CON_NAMES[@]}"; do
        local WEB_IP
        WEB_IP=$(docker inspect --format '{{ range .NetworkSettings.Networks }}{{ .IPAddress }}{{ end }}' "$WEB_CON")

        local WEB_HOST
        WEB_HOST=$(docker inspect --format '{{ .Config.Env }}' "$WEB_CON" | sed 's/^\[//g' | sed 's/\]$//g' | sed 's/, /,/g' | tr " " "\n" | sed 's/,/ /g' | grep VIRTUAL_HOST= | sed -e 's/^VIRTUAL_HOST=//' | sed -e 's/[[:space:]]*$//')

        local WEB_HASH
        WEB_HASH=$(docker inspect --format '{{ .Config.Hostname }}' "$WEB_CON")

        SHALL_BE_PUBLISHED=yes

        # remove the line from temporary file, if existing
        if [[ "remove" == "$HOST_ACTION" ]]; then
            sed -i "/$WEB_HOST/d" "$TEMP_HOSTS_PATH"
            sed -i "/$WEB_HASH/d" "$TEMP_HOSTS_PATH"

        # add the IP => HOST to the temporary file
        elif [[ -n "$WEB_IP" && -n "$WEB_HOST" ]] && ! grep -q "$WEB_HOST" "$TEMP_HOSTS_PATH"; then
            echo -e "$WEB_IP\t\t$WEB_HASH $WEB_HOST" >> "$TEMP_HOSTS_PATH"
        fi
    done

    for APP_CON in "${APP_CON_NAMES[@]}"; do
        local APP_IP
        APP_IP=$(docker inspect --format '{{ range .NetworkSettings.Networks }}{{ .IPAddress }}{{ end }}' "$APP_CON")

        local APP_HASH
        APP_HASH=$(docker inspect --format '{{ .Config.Hostname }}' "$APP_CON")

        SHALL_BE_PUBLISHED=yes

        # remove the line from temporary file, if existing
        if [[ "remove" == "$HOST_ACTION" ]]; then
            sed -i "/$APP_HASH/d" "$TEMP_HOSTS_PATH"

        # add the IP => HOST to the temporary file
        elif [[ -n "$APP_IP" && -n "$APP_HASH" ]] && ! grep "$APP_HASH" "$TEMP_HOSTS_PATH"; then
            echo -e "$APP_IP\t\t$APP_HASH" >> "$TEMP_HOSTS_PATH"
        fi
    done

    if [[ -n "$SHALL_BE_PUBLISHED" ]]; then
        local ACF
        ACF=$(get_container_suffixes "APP")

        local WCF
        WCF=$(get_container_suffixes "WEB")

        publish_host_files "$ACF|$WCF"
    fi
}

# update the hosts file with running proxy containers
function update_host_files_with_proxy() {
    local CON_NAMES=($(docker ps -a --format '{{ .Names }}' -f status='running' -f name='proxy-'))

    if [[ "0" != "${#CON_NAMES[@]}" ]]; then
        for CON in "${CON_NAMES[@]}"; do
            local WEB_IP
            WEB_IP=$(docker inspect --format '{{ range .NetworkSettings.Networks }}{{ .IPAddress }}{{ end }}' "$CON")

            local WEB_HOST
            WEB_HOST=$(docker inspect --format '{{ .Config.Env }}' "$CON" | sed 's/^\[//g' | sed 's/\]$//g' | sed 's/, /,/g' | tr " " "\n" | sed 's/,/ /g' | grep VIRTUAL_HOST= | sed -e 's/^VIRTUAL_HOST=//' | sed -e 's/[[:space:]]*$//')

            local WEB_HASH
            WEB_HASH=$(docker inspect --format '{{ .Config.Hostname }}' "$CON")

            # add the IP => HOST to the temporary file
            if [[ -n "$WEB_IP" ]] && ! grep "$WEB_IP" "$TEMP_HOSTS_PATH" && [[ -n "$WEB_HOST" || -n "$WEB_HASH" ]]; then
                echo -e "$WEB_IP\t\t$WEB_HASH $WEB_HOST" >> "$TEMP_HOSTS_PATH"
            fi
        done
    fi
}

# update the /etc/hosts file in any proxy related container with data from .current-hosts file
function publish_host_files() {
    local HOST_CONTAINER_SUFFIXES=($(echo "$1" | tr "|" "\n"))
    local IGNORED_CONTAINERS=($(echo "$IGNORED_HOSTS_CONTAINERS" | tr "|" "\n"))
    local FORMATTED_CONTAINERS=

    for NEXT_SUFFIX in "${HOST_CONTAINER_SUFFIXES[@]}"; do
        FORMATTED_CONTAINERS=${FORMATTED_CONTAINERS}\ -f\ name="-${NEXT_SUFFIX}"\ -f\ name="_${NEXT_SUFFIX}"
    done

    local COUNTER=0
    local TARGET_CONTAINERS
    local PROXY_CONTAINERS
    TARGET_CONTAINERS=$(docker ps -a --format "{{ .Names }}" -f status="running"${FORMATTED_CONTAINERS})
    PROXY_CONTAINERS=$(docker ps -a --format '{{ .Names }}' -f status='running' -f name='proxy-')

    while read -r CURRENT; do
        if [[ -n "$CURRENT" && ! "${IGNORED_CONTAINERS[*]}" =~ "$CURRENT" ]]; then
            CURRENT_CONTENT=$(docker exec -u root "$CURRENT" /bin/sh -c "cat /etc/hosts")
            CURRENT_CONTENT=$(echo "$CURRENT_CONTENT" | sed '/^### DockerExec hosts file update ###/,$d')
            UPDATED_HOSTS="$CURRENT_CONTENT\n### DockerExec hosts file update ###\n$(cat "$TEMP_HOSTS_PATH")"
            docker exec -u root "$CURRENT" /bin/sh -c "echo '$UPDATED_HOSTS' > /etc/hosts"
            COUNTER=$((COUNTER+1))
        fi
    done <<< "$(printf "%s\n%s" "$TARGET_CONTAINERS" "$PROXY_CONTAINERS")"

    print_info "The /etc/hosts file of $COUNTER proxy containers was updated successfully!"
}

# aggregating and attaching to all running proxy container logs
function attach_to_logs() {
    DOCKER_LOGS=

    if [[ -z "$ATTACH_TO_COMPOSE_LOGS" || "1" == "$ATTACH_TO_COMPOSE_LOGS" ]]; then
        # shellcheck disable=SC2045
        for file in $(ls "$SPAWNS_ENABLED_PATH"); do
            SPAWN_FILE="$SPAWNS_ENABLED_PATH/$file"
            CON_NAME=$(grep "^CONTAINER_NAME=" "$SPAWN_FILE" | sed -e 's/^CONTAINER_NAME=//' | tr -d '"' | sed -e 's/[[:space:]]*$//')
            RUNNING_CONTAINER=$(docker ps -aq -f name="$CON_NAME" -f status="running")

            if [[ -n "$RUNNING_CONTAINER" ]]; then
                DOCKER_LOGS="docker logs --details -f $CON_NAME & $DOCKER_LOGS"
            fi
        done

        # if attaching to logs is enabled, use the "{ command1 & command2 }" notation to aggregate docker logs
        if [[ -n "$DOCKER_LOGS" ]]; then
            DOCKER_LOGS=${DOCKER_LOGS%' & '}
            /bin/sh -c "{ $DOCKER_LOGS; }"
        fi
    fi
}

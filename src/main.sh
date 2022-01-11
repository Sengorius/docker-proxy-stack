#!/usr/bin/env bash

# offer a function to print found hosts as a list
# and also include into the hosts file, if not done yet
function print_hosts() {
    local COMPOSE=$1
    local HOSTS=`grep "VIRTUAL_HOST:" "$COMPOSE" | sed -e 's/VIRTUAL_HOST://' | sed -e 's/[[:space:]]*$//' | sed -e 's/^[[:space:]]*//' | sed 's/, /,/' | sed 's/,/\n/'`

    print_info "Following hosts have been booted:"
    echo "$HOSTS" | while read -r line; do
        if [[ ! -z "$line" ]]; then
            publish_single_entry_hosts_file "$line"
            echo "  https://$line"
        fi
    done
}

# append host to hosts file, if not yet included
function publish_single_entry_hosts_file() {
    # sudo must be given
    sudo true

    local ENTRY=$1
    local HOSTS_HAS_FILE=`egrep -i "^127.0.0.1\s+$ENTRY" "$LINUX_HOSTS"`

    if [[ -f "$LINUX_HOSTS" && -z "$HOSTS_HAS_FILE" ]]; then
        echo "127.0.0.1    $ENTRY" | sudo tee -a "$LINUX_HOSTS" > /dev/null 2>&1
        print_info "'127.0.0.1 $ENTRY' was added to your hosts file"
    fi
}

# offer a function that tries to find the current -app container name
function get_container_names() {
    local ENV_FILE=$1
    local APP_PREFIX=`grep "^CON_PREFIX=" "$ENV_FILE" | sed -e 's/^CON_PREFIX=//' | sed -e 's/[[:space:]]*$//'`
    local APP_NAME=`grep "^CON_NAME=" "$ENV_FILE" | sed -e 's/^CON_NAME=//' | sed -e 's/[[:space:]]*$//'`

    if [[ ! -z "$APP_PREFIX" ]]; then
        local RUNNING_APPS=`docker ps -aq -f name="^$APP_PREFIX((?:-|_).+)*(-|_)(app|php)$" -f status="running"`
        echo "$RUNNING_APPS"
    elif [[ ! -z "$APP_NAME" ]]; then
        echo "$APP_NAME"
    else
        echo ""
    fi

    exit 0
}

# offer a function that tries to find the current -web container name
function get_nginx_names() {
    local ENV_FILE=$1
    local APP_PREFIX=`grep "^CON_PREFIX=" "$ENV_FILE" | sed -e 's/^CON_PREFIX=//' | sed -e 's/[[:space:]]*$//'`
    local APP_NAME=`grep "^CON_NAME=" "$ENV_FILE" | sed -e 's/^CON_NAME=//' | sed -e 's/[[:space:]]*$//'`

    if [[ ! -z "$APP_PREFIX" ]]; then
        local RUNNING_APPS=`docker ps -aq -f name="^$APP_PREFIX((?:-|_).+)*(-|_)web$" -f status="running"`
        echo "$RUNNING_APPS"
    elif [[ ! -z "$APP_NAME" ]]; then
        echo "$APP_NAME"
    else
        echo ""
    fi

    exit 0
}

# offer a function to start compose and enter bash
function compose_run() {
    local COMPOSE=$1
    local ENV_FILE=$2

    docker-compose -f "$COMPOSE" up -d

    if [[ ! -z "$ENV_FILE" ]]; then
        update_host_files "$ENV_FILE"
        local CON_NAMES=(`get_container_names "$ENV_FILE"`)

        if [[ 0 != ${#CON_NAMES[@]} ]]; then
            # retry sh, if bash is not found
            docker exec -it "${CON_NAMES[0]}" bash || \
            docker exec -it "${CON_NAMES[0]}" sh
        fi
    fi
}

# update any running -web and -app containers /etc/hosts file with the new started IP of the current -web container
function update_host_files() {
    local ENV_FILE=$1
    local HOST_ACTION=$2
    local WEB_CON_NAMES=(`get_nginx_names "$ENV_FILE"`)
    local APP_CON_NAMES=(`get_container_names "$ENV_FILE"`)

    if [[ -z "$HOST_ACTION" ]]; then
        HOST_ACTION="append"
    fi

    if [[ 0 != ${#WEB_CON_NAMES[@]} && 0 != ${#APP_CON_NAMES[@]} ]]; then
        SHALL_BE_PUBLISHED=

        for WEB_CON in "${WEB_CON_NAMES[@]}"; do
            WEB_CON_STATE=`docker ps -a --format "table {{.Status}}\t{{.ID}}\t{{.Names}}" | grep "$WEB_CON"`

            if [[ $WEB_CON_STATE == *"Up "* ]]; then
                local WEB_IP=`docker inspect --format '{{ range .NetworkSettings.Networks }}{{ .IPAddress }}{{ end }}' $WEB_CON`
                local WEB_HOST=`docker inspect --format '{{ .Config.Env }}' $WEB_CON | sed 's/^\[//g' | sed 's/\]$//g' | sed 's/, /,/g' | tr " " "\n" | sed 's/,/ /g' | grep VIRTUAL_HOST= | sed -e 's/^VIRTUAL_HOST=//' | sed -e 's/[[:space:]]*$//'`
                local WEB_HASH=`docker inspect --format '{{ .Config.Hostname }}' $WEB_CON`
                SHALL_BE_PUBLISHED=yes

                # remove the line from temporary file, if existing
                if [[ "remove" == "$HOST_ACTION" ]]; then
                    sed -i "/$WEB_HOST/d" "$TEMP_HOSTS_PATH"
                    sed -i "/$WEB_HASH/d" "$TEMP_HOSTS_PATH"

                # add the IP => HOST to the temporary file
                elif [[ ! -z "$WEB_IP" && ! -z "$WEB_HOST" && -z `grep "$WEB_HOST" "$TEMP_HOSTS_PATH"` ]]; then
                    echo -e "$WEB_IP\t\t$WEB_HOST $WEB_HASH" >> "$TEMP_HOSTS_PATH"
                fi
            fi
        done

        for APP_CON in "${APP_CON_NAMES[@]}"; do
            APP_CON_STATE=`docker ps -a --format "table {{.Status}}\t{{.ID}}\t{{.Names}}" | grep "$APP_CON"`

            if [[ $APP_CON_STATE == *"Up "* ]]; then
                local APP_IP=`docker inspect --format '{{ range .NetworkSettings.Networks }}{{ .IPAddress }}{{ end }}' $APP_CON`
                local APP_HASH=`docker inspect --format '{{ .Config.Hostname }}' $APP_CON`
                SHALL_BE_PUBLISHED=yes

                # remove the line from temporary file, if existing
                if [[ "remove" == "$HOST_ACTION" ]]; then
                    sed -i "/$APP_HASH/d" "$TEMP_HOSTS_PATH"

                # add the IP => HOST to the temporary file
                elif [[ ! -z "$APP_IP" && ! -z "$APP_HASH" && -z `grep "$APP_HASH" "$TEMP_HOSTS_PATH"` ]]; then
                    echo -e "$APP_IP\t\t$APP_HASH" >> "$TEMP_HOSTS_PATH"
                fi
            fi
        done

        if [[ ! -z "$SHALL_BE_PUBLISHED" ]]; then
            publish_host_files
        fi
    fi
}

# update the /etc/hosts file in any proxy related container with data from .current-hosts file
function publish_host_files() {
    local TARGET_CONTAINERS=`docker ps -a --format "{{ .Names }}" -f status="running" -f name="-web" -f name="_web" -f name="-php" -f name="_php" -f name="-app" -f name="_app"`
    local COUNTER=0

    while read -r CURRENT; do
        CURRENT_CONTENT=`docker exec $CURRENT /bin/sh -c "cat /etc/hosts"`
        CURRENT_CONTENT=`echo "$CURRENT_CONTENT" | sed '/^### DockerExec hosts file update ###/,$d'`
        UPDATED_HOSTS="$CURRENT_CONTENT\n### DockerExec hosts file update ###\n"`cat $TEMP_HOSTS_PATH`
        docker exec $CURRENT /bin/sh -c "echo '$UPDATED_HOSTS' > /etc/hosts"
        COUNTER=$((COUNTER+1))
    done <<< "$TARGET_CONTAINERS"

    print_info "The /etc/hosts file of $COUNTER proxy containers was updated successfully!"
}

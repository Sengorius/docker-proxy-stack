# simply add leading zeros until at least 3 digits in total
function prepend_zero() {
    local NUMBER=$1

    if [[ ${#NUMBER} -lt 3 ]]; then
        prepend_zero "0$NUMBER"
    else
        echo "$NUMBER"
    fi
}

# make sure necessary directories exist
function ensure_spawns_paths() {
    if [[ ! -d "$SPAWNS_AVAIL_PATH" ]]; then
        mkdir -p "$SPAWNS_AVAIL_PATH"
    fi

    if [[ ! -d "$SPAWNS_ENABLED_PATH" ]]; then
        mkdir -p "$SPAWNS_ENABLED_PATH"
    fi
}

# calculate the next priority +10 or test the given one
function get_next_priority() {
    local MANUAL_PRIO=$1

    # if a manual priority was given, try to find a file with this prio
    if [[ -n "$MANUAL_PRIO" ]]; then
        local EXPANDED_MANUAL_PRIO
        EXPANDED_MANUAL_PRIO=$(prepend_zero "$MANUAL_PRIO")

        local MANUAL_FILE_EXISTS
        MANUAL_FILE_EXISTS=$(ls "$SPAWNS_ENABLED_PATH" | grep "$EXPANDED_MANUAL_PRIO")

        if [[ -z "$MANUAL_FILE_EXISTS" ]]; then
            echo "$EXPANDED_MANUAL_PRIO"
        else
            print_error "A file with priority $EXPANDED_MANUAL_PRIO is already existing!" 1
            exit 1
        fi

    # otherwise calculate the next prio
    else
        local LATEST_PRIO_STRING
        LATEST_PRIO_STRING=$(ls "$SPAWNS_ENABLED_PATH" | sort -r | head -1 | awk -F'-' '{print $1}')

        local LATEST_PRIO_INT
        LATEST_PRIO_INT=$((10#"$LATEST_PRIO_STRING"))

        local LATEST_REST_INT
        LATEST_REST_INT=$((LATEST_PRIO_INT % 10))

        local NEXT_PRIO_INT
        NEXT_PRIO_INT=$((LATEST_PRIO_INT + 10 - LATEST_REST_INT))

        prepend_zero "$NEXT_PRIO_INT"
    fi
}

# make sure to have the proxy container within the spawns-enabled
function ensure_proxy_main() {
    ensure_spawns_paths

    local MAIN_FILE
    # shellcheck disable=SC2010
    MAIN_FILE=$(ls "$SPAWNS_ENABLED_PATH" | grep "main")

    if [[ -z "$MAIN_FILE" ]]; then
        {
            echo "#!/usr/bin/env bash"
            echo
            echo "CONTAINER_NAME=\"proxy-main\""
            echo
            echo "docker run --tty --detach \\"
            echo "    --name \"\${CONTAINER_NAME}\" \\"
            echo "    --publish \"80:80\" \\"
            echo "    --publish \"443:443\" \\"
            echo "    --volume \"\${BASE_DIR}/certs:/etc/nginx/certs\" \\"
            echo "    --volume \"\${BASE_DIR}/conf:/etc/nginx/conf.d\" \\"
            echo "    --volume \"\${BASE_DIR}/dhparam:/etc/nginx/dhparam\" \\"
            echo "    --volume \"\${BASE_DIR}/vhost.d:/etc/nginx/vhost.d\" \\"
            echo "    --volume \"\${SOCK_PATH}:/tmp/docker.sock:ro\" \\"
            echo "    --volume \"\${DATA_PATH}:/var/data\" \\"
            echo "    --network \"\${NETWORK_NAME}\" \\"
            echo "    --restart unless-stopped \\"
            echo "    jwilder/nginx-proxy:alpine"
        } > "$SPAWNS_ENABLED_PATH/000-main"
    fi
}

# enable an available container by linking
function enable_spawn_container() {
    local FILE_NAME=$1
    local MANUAL_PRIO=$2

    if [[ ! -f "$SPAWNS_AVAIL_PATH/$FILE_NAME" || -f "$SPAWNS_ENABLED_PATH/$FILE_NAME" || -h "$SPAWNS_ENABLED_PATH/$FILE_NAME" ]]; then
        print_error "File $SPAWNS_AVAIL_PATH/$FILE_NAME not existing or already enabled." 1
        exit 1
    fi

    if NEXT_PRIO=$(get_next_priority "$MANUAL_PRIO"); then
        ln -s "$SPAWNS_AVAIL_PATH/$FILE_NAME" "$SPAWNS_ENABLED_PATH/$NEXT_PRIO-$FILE_NAME"
        print_info "Enabled spawn $NEXT_PRIO-$FILE_NAME"

        if [[ 1 == $(is_proxy_running) ]]; then
            start_spawn_container "$NEXT_PRIO-$FILE_NAME"
            update_host_files_with_proxy > /dev/null
            publish_host_files "APP" > /dev/null
        fi
    else
        echo "$NEXT_PRIO"
        exit 1
    fi
}

# disable an available container by unlinking or removing a file
function disable_spawn_container() {
    local FILE_NAME=$1
    local FILE_EXISTING
    FILE_EXISTING=$(find "$SPAWNS_ENABLED_PATH" -maxdepth 1 -type f,l -regex ".*$FILE_NAME$")

    if [[ -z "$FILE_EXISTING" ]]; then
        print_error "File $SPAWNS_ENABLED_PATH/$FILE_NAME not existing or already disabled." 1
        exit 1
    fi

    echo "$FILE_EXISTING" | while read -r file; do
        CON_NAME=$(grep "^CONTAINER_NAME=" "$file" | sed -e 's/^CONTAINER_NAME=//' | tr -d '"' | sed -e 's/[[:space:]]*$//')
        RUNNING_CONTAINER=$(docker ps -aq -f name="$CON_NAME")

        if [[ -n "$CON_NAME" && -n "$RUNNING_CONTAINER" ]]; then
            print_info "Stopping container $CON_NAME"
            docker stop "$CON_NAME" > /dev/null
            docker rm -f "$CON_NAME" > /dev/null
        fi

        if [[ -h "$file" ]]; then
            rm "$file"
        else
            BASE_FILE=$(basename "$file")
            mv "$file" "$SPAWNS_AVAIL_PATH/$BASE_FILE"
        fi

        print_info "Disabled spawn $file"
    done
}

# create a new spawn in spawns-available, if possible
function spawn_container_from_questions() {
    CONTAINER_NAME=$(match_answer_or_default "Give a short name for this container [e.g. mysql]: ")
    if [[ -z "$CONTAINER_NAME" ]]; then
        print_warning "A short name for this new container is necessary!"
        exit 1
    fi

    CONTAINER_IMAGE=$(match_answer_or_default "What is the image and tag for this container [e.g. adminer:latest]: ")
    if [[ -z "$CONTAINER_IMAGE" ]]; then
        print_warning "The image for this new container is necessary!"
        exit 1
    fi

    ENABLE_CONTAINER=$(match_answer_or_default "Enable spawn after creation? [yes]" "yes")

    spawn_container "$CONTAINER_NAME" "$CONTAINER_IMAGE"
    print_info "Created spawn file '$CONTAINER_NAME' in $SPAWNS_AVAIL_PATH"

    case "$ENABLE_CONTAINER" in
        [yY][eE][sS]|[yY])
            enable_spawn_container "$CONTAINER_NAME"
            ;;
    esac
}

# create a new spawn in spawns-available from given info
function spawn_container() {
    local CONTAINER_NAME=$1
    local CONTAINER_IMAGE=$2
    local ADDITIONAL_ENVS=$3
    local ADDITIONAL_VOLUMES=$4
    local PROXY_NAME="proxy-$CONTAINER_NAME"

    ensure_spawns_paths

    if [[ ! -f "$SPAWNS_AVAIL_PATH/$CONTAINER_NAME" ]]; then
        {
            echo "#!/usr/bin/env bash"
            echo
            echo "CONTAINER_NAME=\"$PROXY_NAME\""
            echo
            echo "docker run --tty --detach \\"
            echo "    --name \"\${CONTAINER_NAME}\" \\"
            [ -n "$ADDITIONAL_VOLUMES" ] && (echo "$ADDITIONAL_VOLUMES" | awk '{print "    --volume \""$1"\" \\"}')
            echo "    --network \"\${NETWORK_NAME}\" \\"
            echo "    --restart unless-stopped \\"
            echo "    --env VIRTUAL_HOST=$CONTAINER_NAME.docker.test \\"
            [ -n "$ADDITIONAL_ENVS" ] && (echo "$ADDITIONAL_ENVS" | awk '{print "    --env "$1" \\"}')
            echo "    $CONTAINER_IMAGE"
        } > "$SPAWNS_AVAIL_PATH/$CONTAINER_NAME"
    else
        print_error "File $SPAWNS_AVAIL_PATH/$CONTAINER_NAME already existing!" 1
        exit 1
    fi
}

# spawn SMT mailcatcher file
function spawn_smt_mailcatcher() {
    if spawn_container "mailcatcher" "sengorius/proxy-mailcatcher:latest" "VIRTUAL_PORT=443"; then
        print_info "Created a spawn with Skript-Manufaktur mailcatcher image"
    fi
}

# ask and spawn the legacy containers from Docker-Proxy v1 (docker-compose)
function spawn_legacy_proxy_stack() {
    ensure_spawns_paths

    MYSQL5=$(match_answer_or_default "Create mysql:5.7 container? [yes]" "yes")
    case "$MYSQL5" in
        [yY][eE][sS]|[yY])
            if [[ ! -f "$SPAWNS_AVAIL_PATH/mysql5" ]]; then
                {
                    echo "#!/usr/bin/env bash"
                    echo
                    echo "CONTAINER_NAME=\"proxy-db\""
                    echo
                    echo "docker run --tty --detach \\"
                    echo "    --name \"\${CONTAINER_NAME}\" \\"
                    echo "    --volume \"docker-proxy-stack_data-db:/var/lib/mysql\" \\"
                    echo "    --volume \"\${DATA_PATH}:/var/data\" \\"
                    echo "    --network \"\${NETWORK_NAME}\" \\"
                    echo "    --restart unless-stopped \\"
                    echo "    --env MYSQL_ROOT_PASSWORD=root \\"
                    echo "    --env MYSQL_PORT=3306 \\"
                    echo "    mysql:5.7 --character-set-server=utf8mb4 \\"
                    echo "              --collation-server=utf8mb4_unicode_ci \\"
                    echo "              --sql_mode=\"STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION\""
                } > "$SPAWNS_AVAIL_PATH/mysql5"

                print_info "Created $SPAWNS_AVAIL_PATH/mysql5!"
            else
                print_warning "File $SPAWNS_AVAIL_PATH/mysql5 already existing!" 1
            fi

            MYSQL5_ENABLE=$(match_answer_or_default "Enable mysql container? [yes]" "yes")
            case "$MYSQL5_ENABLE" in
                [yY][eE][sS]|[yY])
                    enable_spawn_container "mysql5" 3
                    ;;
            esac
            ;;
    esac

    POSTGRES12=$(match_answer_or_default "Create postgres:12 container? [yes]" "yes")
    case "$POSTGRES12" in
        [yY][eE][sS]|[yY])
            if [[ ! -f "$SPAWNS_AVAIL_PATH/postgres12" ]]; then
                {
                    echo "#!/usr/bin/env bash"
                    echo
                    echo "CONTAINER_NAME=\"proxy-pg\""
                    echo
                    echo "docker run --tty --detach \\"
                    echo "    --name \"\${CONTAINER_NAME}\" \\"
                    echo "    --volume \"docker-proxy-stack_data-pg:/var/lib/postgresql/data\" \\"
                    echo "    --volume \"\${DATA_PATH}:/var/data\" \\"
                    echo "    --network \"\${NETWORK_NAME}\" \\"
                    echo "    --restart unless-stopped \\"
                    echo "    --env POSTGRES_USER=root \\"
                    echo "    --env POSTGRES_PASSWORD=root \\"
                    echo "    --env POSTGRES_PORT=5432 \\"
                    echo "    postgres:12"
                } > "$SPAWNS_AVAIL_PATH/postgres12"

                print_info "Created $SPAWNS_AVAIL_PATH/postgres12!"
            else
                print_warning "File $SPAWNS_AVAIL_PATH/postgres12 already existing!" 1
            fi

            POSTGRES12_ENABLE=$(match_answer_or_default "Enable postgres container? [yes]" "yes")
            case "$POSTGRES12_ENABLE" in
                [yY][eE][sS]|[yY])
                    enable_spawn_container "postgres12" 4
                    ;;
            esac
            ;;
    esac

    REDIS6=$(match_answer_or_default "Create redis:6 container? [yes]" "yes")
    case "$REDIS6" in
        [yY][eE][sS]|[yY])
            if [[ ! -f "$SPAWNS_AVAIL_PATH/redis6" ]]; then
                {
                    echo "#!/usr/bin/env bash"
                    echo
                    echo "CONTAINER_NAME=\"proxy-redis\""
                    echo
                    echo "docker run --tty --detach \\"
                    echo "    --name \"\${CONTAINER_NAME}\" \\"
                    echo "    --volume \"docker-proxy-stack_data-redis:/data\" \\"
                    echo "    --volume \"\${DATA_PATH}:/var/data\" \\"
                    echo "    --network \"\${NETWORK_NAME}\" \\"
                    echo "    --restart unless-stopped \\"
                    echo "    --env REDIS_PASSWORD=root \\"
                    echo "    --env REDIS_PORT=6379 \\"
                    echo "    redis:6 --appendonly yes"
                } > "$SPAWNS_AVAIL_PATH/redis6"

                print_info "Created $SPAWNS_AVAIL_PATH/redis6!"
            else
                print_warning "File $SPAWNS_AVAIL_PATH/redis6 already existing!" 1
            fi

            REDIS6_ENABLE=$(match_answer_or_default "Enable redis container? [yes]" "yes")
            case "$REDIS6_ENABLE" in
                [yY][eE][sS]|[yY])
                    enable_spawn_container "redis6" 5
                    ;;
            esac
            ;;
    esac

    ADMINER=$(match_answer_or_default "Create adminer:latest container? [yes]" "yes")
    case "$ADMINER" in
        [yY][eE][sS]|[yY])
            if [[ ! -f "$SPAWNS_AVAIL_PATH/adminer" ]]; then
                {
                    echo "#!/usr/bin/env bash"
                    echo
                    echo "CONTAINER_NAME=\"proxy-adminer\""
                    echo
                    echo "docker run --tty --detach \\"
                    echo "    --name \"\${CONTAINER_NAME}\" \\"
                    echo "    --volume \"\${DATA_PATH}:/var/data\" \\"
                    echo "    --network \"\${NETWORK_NAME}\" \\"
                    echo "    --restart unless-stopped \\"
                    echo "    --env VIRTUAL_HOST=adminer.docker.test \\"
                    echo "    --env VIRTUAL_PORT=8080 \\"
                    echo "    --env ADMINER_DEFAULT_SERVER=proxy-pg \\"
                    echo "    --env ADMINER_PLUGINS=\"tables-filter tinymce edit-calendar\" \\"
                    echo "    --env ADMINER_DESIGN=rmsoft \\"
                    echo "    adminer:latest"
                } > "$SPAWNS_AVAIL_PATH/adminer"

                print_info "Created $SPAWNS_AVAIL_PATH/adminer!"
            else
                print_warning "File $SPAWNS_AVAIL_PATH/adminer already existing!" 1
            fi

            ADMINER_ENABLE=$(match_answer_or_default "Enable adminer container? [yes]" "yes")
            case "$ADMINER_ENABLE" in
                [yY][eE][sS]|[yY])
                    enable_spawn_container "adminer" 10
                    ;;
            esac
            ;;
    esac

    PMA=$(match_answer_or_default "Create phpmyadmin:latest container? [yes]" "yes")
    case "$PMA" in
        [yY][eE][sS]|[yY])
            if [[ ! -f "$SPAWNS_AVAIL_PATH/phpmyadmin" ]]; then
                {
                    echo "#!/usr/bin/env bash"
                    echo
                    echo "CONTAINER_NAME=\"proxy-pma\""
                    echo
                    echo "docker run --tty --detach \\"
                    echo "    --name \"\${CONTAINER_NAME}\" \\"
                    echo "    --volume \"\${DATA_PATH}:/var/data\" \\"
                    echo "    --network \"\${NETWORK_NAME}\" \\"
                    echo "    --restart unless-stopped \\"
                    echo "    --env VIRTUAL_HOST=pma.docker.test \\"
                    echo "    --env VIRTUAL_PORT=80 \\"
                    echo "    --env PMA_ARBITRARY=1 \\"
                    echo "    --env PMA_HOST=proxy-db \\"
                    echo "    --env PMA_USER=root \\"
                    echo "    --env PMA_PASSWORD=root \\"
                    echo "    phpmyadmin:latest"
                } > "$SPAWNS_AVAIL_PATH/phpmyadmin"

                print_info "Created $SPAWNS_AVAIL_PATH/phpmyadmin!"
            else
                print_warning "File $SPAWNS_AVAIL_PATH/phpmyadmin already existing!" 1
            fi

            PMA_ENABLE=$(match_answer_or_default "Enable phpmyadmin container? [yes]" "yes")
            case "$PMA_ENABLE" in
                [yY][eE][sS]|[yY])
                    enable_spawn_container "phpmyadmin" 20
                    ;;
            esac
            ;;
    esac

    MAILCATCHER=$(match_answer_or_default "Create sengorius/proxy-mailcatcher:latest container? [yes]" "yes")
    case "$MAILCATCHER" in
        [yY][eE][sS]|[yY])
            spawn_smt_mailcatcher

            MAILCATCHER_ENABLE=$(match_answer_or_default "Enable mailcatcher container? [yes]" "yes")
            case "$MAILCATCHER_ENABLE" in
                [yY][eE][sS]|[yY])
                    enable_spawn_container "mailcatcher" 30
                    ;;
            esac
            ;;
    esac
}

#!/usr/bin/env bash

# offer a function to test a directory on having valid .env and (.yml or .yaml)
function test_files() {
    local ENV_FILE=$1
    local COMPOSE=$2
    local COMPOSE_V1="$COMPOSE.yml"
    local COMPOSE_V2="$COMPOSE.yaml"

    if [[ ! ( -e "$ENV_FILE" || -f "$ENV_FILE" ) ]]; then
        print_error "The $ENV_FILE file was not found! Are you located in your project directory?" 1
        exit 1
    fi

    if [[ ! ( -e "$COMPOSE_V1" || -f "$COMPOSE_V1" ) ]]; then
        if [[ ! ( -e "$COMPOSE_V2" || -f "$COMPOSE_V2" ) ]]; then
            print_error "No $COMPOSE_V1 or $COMPOSE_V2 file was found! Are you located in your project directory?" 1
            exit 1
        else
            echo "$COMPOSE_V2"
        fi
    else
        echo "$COMPOSE_V1"
    fi

    exit 0
}

function test_files_proxy() {
    local ENV_FILE=$1
    local COMPOSE=$2
    local COMPOSE_V1="$COMPOSE.yml"
    local COMPOSE_V2="$COMPOSE.yaml"

    if [[ ! ( -e "$ENV_FILE" || -f "$ENV_FILE" ) ]]; then
        print_error "The $ENV_FILE file was not found! The proxy-stack is not configured, yet!" 1
        exit 1
    fi

    if [[ ! ( -e "$COMPOSE_V1" || -f "$COMPOSE_V1" ) ]]; then
        if [[ ! ( -e "$COMPOSE_V2" || -f "$COMPOSE_V2" ) ]]; then
            print_error "No $COMPOSE_V1 or $COMPOSE_V2 file was found! Something is wrong here..." 1
            exit 1
        else
            echo "$COMPOSE_V2"
        fi
    else
        echo "$COMPOSE_V1"
    fi

    exit 0
}

# test if the proxy setup was already initialized
function is_proxy_running() {
    STATUS=$(docker ps -a --format "{{ .Names }}" -f status="running" -f name="proxy-nginx")

    if [[ -z "$STATUS" ]]; then
        echo 0
    else
        echo 1
    fi
}

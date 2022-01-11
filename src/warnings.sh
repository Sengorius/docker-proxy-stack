#!/usr/bin/env bash

###
### Colors
###

export COLOR_BLUE="\033[0;36m"
export COLOR_GREEN="\033[0;32m"
export COLOR_ORANGE="\033[0;33m"
export COLOR_RED="\033[0;31m"
export COLOR_WHITE='\033[0m'

# add colorize functions
function print_error() {
    local MESSAGE=$1
    local NEWLINE=$2

    if [[ -z "$NEWLINE" ]]; then
        NEWLINE=0
    fi

    echo -e "${COLOR_RED}$MESSAGE${COLOR_WHITE}"

    if [[ "1" == "$NEWLINE" ]]; then
        echo
    fi
}

function print_info() {
    local MESSAGE=$1
    local NEWLINE=$2

    if [[ -z "$NEWLINE" ]]; then
        NEWLINE=0
    fi

    echo -e "${COLOR_BLUE}$MESSAGE${COLOR_WHITE}"

    if [[ "1" == "$NEWLINE" ]]; then
        echo
    fi
}

function print_warning() {
    local MESSAGE=$1
    local NEWLINE=$2

    if [[ -z "$NEWLINE" ]]; then
        NEWLINE=0
    fi

    echo -e "${COLOR_ORANGE}$MESSAGE${COLOR_WHITE}"

    if [[ "1" == "$NEWLINE" ]]; then
        echo
    fi
}

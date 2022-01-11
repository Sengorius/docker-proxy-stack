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

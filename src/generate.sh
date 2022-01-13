#!/usr/bin/env bash

function generate_docker_compose_project() {
    local FILE_PATH=$1
    local DOMAIN_PREFIX=$2

    {
        echo "version: '3.5'"
        echo
        echo "services:"
        echo "    web:"
        echo "       image: \${WEB_IMAGE}"
        echo "       container_name: \${CON_PREFIX}-web"
        echo "       env_file: .env"
        echo "       volumes:"
        echo "           - .:/var/www/html"
        echo "       expose:"
        echo "           - 80"
        echo "           - 443"
        echo "       environment:"
        echo "           VIRTUAL_HOST: ${DOMAIN_PREFIX}.docker.test"
        echo "           VIRTUAL_PORT: 443"
        echo "           VIRTUAL_PROTO: https"
        echo "       links:"
        echo "           - php"
        echo
        echo "    php:"
        echo "        image: \${PHP_IMAGE}"
        echo "        container_name: \${CON_PREFIX}-app"
        echo "        env_file: .env"
        echo "        volumes:"
        echo "            - .:/var/www/html"
        echo
        echo "networks:"
        echo "    default:"
        echo "        external: true"
        echo "        name: \${NETWORK}"
        echo
    } > "$FILE_PATH"
}

# creates a .env file with basic configuration for the proxy
function generate_env_file_project() {
    local FILE_PATH=$1
    local DOMAIN_PREFIX=$2

    {
        echo "# docker-compose configuration"
        echo "CON_PREFIX=${DOMAIN_PREFIX}"
        echo "PHP_IMAGE=php:fpm"
        echo "WEB_IMAGE=nginx/nginx:latest"
        echo "NETWORK=proxy-network"
        echo "START_CONTAINER=${DOMAIN_PREFIX}-app"
        echo
    } > "$FILE_PATH"
}

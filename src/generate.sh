# does the openssl certificate generation for the proxy to work with SSL
function generate_openssl_certs() {
    local RSA_COMMAND=openssl
    local RSA_KEY_LENGTH=$1
    local RSA_VALID_DAYS=$2
    local RSA_COUNTRY_NAME=$3
    local RSA_STATE_NAME=$4
    local RSA_LOCALITY_NAME=$5
    local RSA_ORG_NAME=$6
    local RSA_ORGUNIT_NAME=$7
    local RSA_EMAIL=$8
    local SUBDOMAIN=$9

    # create complex variables
    local CN
    local DOMAIN_ALT_NAMES
    local KEYFILE
    local ROOTCA

    if [[ -n "$SUBDOMAIN" ]]; then
        CN="$SUBDOMAIN.docker.test"
        DOMAIN_ALT_NAMES="DNS:$SUBDOMAIN.docker.test,DNS:*.$SUBDOMAIN.docker.test"
        KEYFILE="$CERTS_PATH/$SUBDOMAIN.docker.test"
        ROOTCA="$CERTS_PATH/$SUBDOMAIN.rootCA"
    else
        CN="docker.test"
        DOMAIN_ALT_NAMES="DNS:docker.test,DNS:*.docker.test,DNS:localhost,DNS:127.0.0.1,DNS:0:0:0:0:0:0:0:1"
        KEYFILE="$CERTS_PATH/docker.test"
        ROOTCA="$CERTS_PATH/rootCA"
    fi

    local CERT_SUBJECT="/C=$RSA_COUNTRY_NAME/ST=$RSA_STATE_NAME/L=$RSA_LOCALITY_NAME/O=$RSA_ORG_NAME/OU=$RSA_ORGUNIT_NAME/emailAddress=$RSA_EMAIL/CN=$CN"

    if ! command -v openssl; then
        print_warning "Openssl seems not to be installed on this machine. But it is necessary to generate keys..." 1
        exit 1

        #print_warning "Openssl seems not to be installed on this machine. Trying to install with docker."
        #RSA_COMMAND=docker\ run\ --user\ "$(id -u):$(id -g)"\ -i\ -v\ "${CERTS_PATH}:/export"\ "${OPENSSL_IMAGE}"\ openssl
        #CERTS_PATH=/export
    fi

    # create a root key and rootCA for docker.test
    ${RSA_COMMAND} genrsa -out "$ROOTCA.key" "$RSA_KEY_LENGTH"
    ${RSA_COMMAND} req -x509 -new -nodes -sha256 \
        -key "$ROOTCA.key" \
        -subj "$CERT_SUBJECT" \
        -days "$RSA_VALID_DAYS" \
        -out "$ROOTCA.crt"

    # create a certificate for docker.test
    ${RSA_COMMAND} genrsa -out "$KEYFILE.key" "$RSA_KEY_LENGTH"
    ${RSA_COMMAND} req -new -sha256 \
        -key "$KEYFILE.key" \
        -subj "$CERT_SUBJECT" \
        -reqexts SAN \
        -config <(cat /etc/ssl/openssl.cnf <(printf "\n[SAN]\nsubjectAltName=$DOMAIN_ALT_NAMES")) \
        -out "$KEYFILE.csr"

    # last step: sign the domain certificate with the rootCA
    ${RSA_COMMAND} x509 -req -sha256 -CAcreateserial \
        -in "$KEYFILE.csr" \
        -CA "$ROOTCA.crt" \
        -CAkey "$ROOTCA.key" \
        -out "$KEYFILE.crt" \
        -days "$RSA_VALID_DAYS" \
        -extfile <(printf "subjectAltName=$DOMAIN_ALT_NAMES")
}

# creates a docker-compose.proxy.yaml with some default configuration for php + nginx
function generate_docker_compose_project() {
    local FILE_PATH=$1
    local DOMAIN_PREFIX=$2

    {
        echo "services:"
        echo "    web:"
        echo "       image: \${WEB_IMAGE}"
        echo "       container_name: \${CON_PREFIX}-web"
        echo "       env_file: .env"
        echo "       volumes:"
        echo "           - .:/var/www/html"
        echo "       environment:"
        echo "           VIRTUAL_HOST: ${DOMAIN_PREFIX}.docker.test"
        echo "           VIRTUAL_PORT: 443"
        echo "           VIRTUAL_PROTO: https"
        echo "           NGINX_PHP_HOST: \${CON_PREFIX}-app"
        echo "       depends_on:"
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
    } > "$FILE_PATH"
}

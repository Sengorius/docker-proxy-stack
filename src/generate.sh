# reads a certificate subject as an openssl '-subj' compatible string; pass 1 as second argument to
# drop the common name from the result
function read_cert_subject() {
    local CERT_FILE=$1
    local SKIP_CN=$2
    local SUBJECT_LINES

    SUBJECT_LINES="$(openssl x509 -in "$CERT_FILE" -noout -subject -nameopt sep_multiline,utf8,esc_ctrl \
        | tail -n +2 \
        | sed -e 's/^[[:space:]]*//' -e '/^$/d')"

    if [[ "1" == "$SKIP_CN" ]]; then
        SUBJECT_LINES="$(printf '%s\n' "$SUBJECT_LINES" | grep -v '^CN=')"
    fi

    printf '%s\n' "$SUBJECT_LINES" | awk '{ printf "/%s", $0 }'
}

# builds the subject for a host certificate out of the subject of its rootCA
function build_host_subject() {
    local ROOTCA_CRT=$1
    local CN=$2
    local CA_SUBJECT BASE_SUBJECT HOST_SUBJECT

    CA_SUBJECT="$(read_cert_subject "$ROOTCA_CRT" 0)"
    BASE_SUBJECT="$(read_cert_subject "$ROOTCA_CRT" 1)"
    HOST_SUBJECT="$BASE_SUBJECT/CN=$CN"

    # a host certificate must never share its subject with its own rootCA: OpenSSL would take it for
    # self-signed (EXFLAG_SS), never look for an issuer and fail with "self-signed certificate"
    if [[ "$HOST_SUBJECT" == "$CA_SUBJECT" ]]; then
        HOST_SUBJECT="$BASE_SUBJECT/OU=Host Certificate/CN=$CN"
    fi

    printf '%s' "$HOST_SUBJECT"
}

# reads the subjectAltName of a certificate; IP addresses noted as DNS entries are kept, but get an
# additional, formally correct IP entry
function read_cert_alt_names() {
    local CERT_FILE=$1
    local ALT_NAMES RESULT VALUE
    local IP_NAMES=""

    ALT_NAMES="$(openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null \
        | tail -n +2 \
        | tr -d '[:space:]')"

    if [[ -z "$ALT_NAMES" ]]; then
        return
    fi

    RESULT="$ALT_NAMES"

    for ENTRY in ${ALT_NAMES//,/ }; do
        if [[ "$ENTRY" != DNS:* ]]; then
            continue
        fi

        VALUE="${ENTRY#DNS:}"

        # IPv4 and IPv6 addresses belong into the SAN as IP entries, not as DNS entries
        if [[ "$VALUE" =~ ^[0-9]+(\.[0-9]+){3}$ || "$VALUE" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*$ ]]; then
            if [[ ",$RESULT," != *",IP:$VALUE,"* ]]; then
                IP_NAMES="$IP_NAMES,IP:$VALUE"
            fi
        fi
    done

    printf '%s%s' "$RESULT" "$IP_NAMES"
}

# builds the extensions a host certificate needs to be usable as a leaf in a verifiable chain
function build_host_cert_extensions() {
    local DOMAIN_ALT_NAMES=$1

    # the authorityKeyIdentifier is the crucial one: without it OpenSSL cannot link the certificate to
    # its issuer, as soon as both share a subject; current OpenSSL versions add it on their own, older
    # ones (1.1.x) did not
    printf "basicConstraints=critical,CA:FALSE\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nsubjectAltName=%s\n" "$DOMAIN_ALT_NAMES"
}

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
        DOMAIN_ALT_NAMES="DNS:docker.test,DNS:*.docker.test,DNS:localhost,DNS:127.0.0.1,DNS:0:0:0:0:0:0:0:1,IP:127.0.0.1,IP:0:0:0:0:0:0:0:1"
        KEYFILE="$CERTS_PATH/docker.test"
        ROOTCA="$CERTS_PATH/rootCA"
    fi

    # the rootCA and the host certificate need distinct subjects, or OpenSSL will not build the chain
    local CERT_SUBJECT_BASE="/C=$RSA_COUNTRY_NAME/ST=$RSA_STATE_NAME/L=$RSA_LOCALITY_NAME/O=$RSA_ORG_NAME/OU=$RSA_ORGUNIT_NAME/emailAddress=$RSA_EMAIL"
    local ROOTCA_SUBJECT="$CERT_SUBJECT_BASE/CN=$CN Root CA"
    local HOST_SUBJECT="$CERT_SUBJECT_BASE/CN=$CN"

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
        -subj "$ROOTCA_SUBJECT" \
        -days "$RSA_VALID_DAYS" \
        -out "$ROOTCA.crt"

    # create a certificate for docker.test
    ${RSA_COMMAND} genrsa -out "$KEYFILE.key" "$RSA_KEY_LENGTH"
    ${RSA_COMMAND} req -new -sha256 \
        -key "$KEYFILE.key" \
        -subj "$HOST_SUBJECT" \
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
        -extfile <(build_host_cert_extensions "$DOMAIN_ALT_NAMES")
}

# re-issues a host certificate under its existing rootCA; the rootCA and its key stay untouched, so a
# rootCA that was registered in a browser does not have to be imported again
function renew_openssl_host_cert() {
    local RSA_COMMAND=openssl
    local RSA_KEY_LENGTH=$1
    local RSA_VALID_DAYS=$2
    local SUBDOMAIN=$3

    local CN KEYFILE ROOTCA DOMAIN_ALT_NAMES HOST_SUBJECT
    local BACKUP_PATH TIMESTAMP BASE_NAME EXTENSION
    local CRT_FILE CSR_FILE KEY_FILE

    if [[ -n "$SUBDOMAIN" ]]; then
        CN="$SUBDOMAIN.docker.test"
        DOMAIN_ALT_NAMES="DNS:$SUBDOMAIN.docker.test,DNS:*.$SUBDOMAIN.docker.test"
        KEYFILE="$CERTS_PATH/$SUBDOMAIN.docker.test"
        ROOTCA="$CERTS_PATH/$SUBDOMAIN.rootCA"
    else
        CN="docker.test"
        DOMAIN_ALT_NAMES="DNS:docker.test,DNS:*.docker.test,DNS:localhost,DNS:127.0.0.1,DNS:0:0:0:0:0:0:0:1,IP:127.0.0.1,IP:0:0:0:0:0:0:0:1"
        KEYFILE="$CERTS_PATH/docker.test"
        ROOTCA="$CERTS_PATH/rootCA"
    fi

    if ! command -v openssl > /dev/null 2>&1; then
        print_error "Openssl seems not to be installed on this machine. But it is necessary to generate keys..." 1
        return 1
    fi

    # the rootCA has to exist; this function will never create one
    if [[ ! -f "$ROOTCA.crt" || ! -f "$ROOTCA.key" ]]; then
        print_error "Could not find $ROOTCA.crt and $ROOTCA.key. Use 'DockerExec init-certs' or 'DockerExec add-cert' to create a rootCA first." 1
        return 1
    fi

    # keep the alternative names of the current certificate, if there is one
    if [[ -f "$KEYFILE.crt" ]]; then
        local CURRENT_ALT_NAMES
        CURRENT_ALT_NAMES="$(read_cert_alt_names "$KEYFILE.crt")"

        if [[ -n "$CURRENT_ALT_NAMES" ]]; then
            DOMAIN_ALT_NAMES="$CURRENT_ALT_NAMES"
        fi
    fi

    HOST_SUBJECT="$(build_host_subject "$ROOTCA.crt" "$CN")"

    # never touch symlinks like default.crt, always write the files they point to
    CRT_FILE="$(readlink -f "$KEYFILE.crt")"
    CSR_FILE="$(readlink -f "$KEYFILE.csr")"
    KEY_FILE="$(readlink -f "$KEYFILE.key")"

    # back up whatever is there, nothing gets deleted
    BACKUP_PATH="$CERTS_PATH/backup"
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    BASE_NAME="$(basename "$KEYFILE")"
    mkdir -p "$BACKUP_PATH"

    for EXTENSION in crt csr key; do
        if [[ -f "$KEYFILE.$EXTENSION" ]]; then
            cp -L "$KEYFILE.$EXTENSION" "$BACKUP_PATH/$BASE_NAME.$TIMESTAMP.$EXTENSION"
        fi
    done

    print_info "Saved the current certificate files to $BACKUP_PATH/$BASE_NAME.$TIMESTAMP.*"
    print_info "Issuing a new certificate for $CN with subject $HOST_SUBJECT"

    # create a new key and signing request for the host
    ${RSA_COMMAND} genrsa -out "$KEY_FILE" "$RSA_KEY_LENGTH"
    ${RSA_COMMAND} req -new -sha256 \
        -key "$KEY_FILE" \
        -subj "$HOST_SUBJECT" \
        -reqexts SAN \
        -config <(cat /etc/ssl/openssl.cnf <(printf "\n[SAN]\nsubjectAltName=$DOMAIN_ALT_NAMES")) \
        -out "$CSR_FILE"

    # sign it with the existing rootCA
    ${RSA_COMMAND} x509 -req -sha256 -CAcreateserial \
        -in "$CSR_FILE" \
        -CA "$ROOTCA.crt" \
        -CAkey "$ROOTCA.key" \
        -out "$CRT_FILE" \
        -days "$RSA_VALID_DAYS" \
        -extfile <(build_host_cert_extensions "$DOMAIN_ALT_NAMES")

    chmod 644 "$CRT_FILE"

    # the subjects differ now, so 'openssl verify' gives a meaningful answer
    if ! ${RSA_COMMAND} verify -CAfile "$ROOTCA.crt" "$CRT_FILE" > /dev/null 2>&1; then
        print_error "The new certificate $CRT_FILE could not be verified against $ROOTCA.crt!" 1
        return 1
    fi

    print_info "The certificate $CRT_FILE verifies against $ROOTCA.crt."
}

# creates a docker-compose.proxy.yaml with some default configuration for php + nginx
function generate_docker_compose_project() {
    local FILE_PATH=$1
    local DOMAIN_PREFIX=$2

    {
        echo "services:"
        echo "  web:"
        echo "    image: \${WEB_IMAGE}"
        echo "    container_name: \${CON_PREFIX}-web"
        echo "    volumes:"
        echo "      - .:/var/www/html"
        echo "    environment:"
        echo "      VIRTUAL_HOST: ${DOMAIN_PREFIX}.docker.test"
        echo "      NGINX_PHP_HOST: \${CON_PREFIX}-app"
        echo "    depends_on:"
        echo "      - php"
        echo
        echo "  php:"
        echo "    image: \${PHP_IMAGE}"
        echo "    container_name: \${CON_PREFIX}-app"
        echo "    volumes:"
        echo "      - .:/var/www/html"
        echo
        echo "networks:"
        echo "  default:"
        echo "    name: \${NETWORK}"
        echo "    external: true"
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

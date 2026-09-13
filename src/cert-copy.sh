function detect_distro() {
    local CONTAINER=$1
    local DISTRO

    DISTRO="$(docker exec "$CONTAINER" sh -c '
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo "${ID:-unknown}"
        elif [ -f /etc/alpine-release ]; then
            echo "alpine"
        else
            echo "unknown"
        fi
    ')"

    echo "$DISTRO"
}

# tests whether a certificate really carries the signature of a possible issuer; this has to be a
# cryptographic check, because 'openssl verify' only compares names and reports "self-signed", as soon
# as a certificate shares its subject with its issuer
function is_signed_by() {
    local CHILD=$1
    local ISSUER=$2
    local WORK_DIR TBS_OFFSET SIG_OFFSET SIG_ALGORITHM DIGEST
    local RESULT=1

    WORK_DIR="$(mktemp -d)"

    if openssl x509 -in "$CHILD" -outform DER -out "$WORK_DIR/child.der" 2>/dev/null; then
        # the tbsCertificate is the first element inside the certificate, the signature the last bit string
        TBS_OFFSET="$(openssl asn1parse -in "$WORK_DIR/child.der" -inform DER 2>/dev/null | sed -n '2p' | cut -d: -f1 | tr -d ' ')"
        SIG_OFFSET="$(openssl asn1parse -in "$WORK_DIR/child.der" -inform DER 2>/dev/null | grep 'BIT STRING' | tail -1 | cut -d: -f1 | tr -d ' ')"
        SIG_ALGORITHM="$(openssl x509 -in "$CHILD" -noout -text 2>/dev/null | awk '/Signature Algorithm/ { print $3; exit }')"
        DIGEST="${SIG_ALGORITHM%%With*}"

        if [[ -n "$TBS_OFFSET" && -n "$SIG_OFFSET" && -n "$DIGEST" ]]; then
            openssl asn1parse -in "$WORK_DIR/child.der" -inform DER -strparse "$TBS_OFFSET" -noout -out "$WORK_DIR/tbs.der" 2>/dev/null
            openssl asn1parse -in "$WORK_DIR/child.der" -inform DER -strparse "$SIG_OFFSET" -noout -out "$WORK_DIR/signature.bin" 2>/dev/null
            openssl x509 -in "$ISSUER" -noout -pubkey > "$WORK_DIR/issuer-pubkey.pem" 2>/dev/null

            if openssl dgst -"$DIGEST" -verify "$WORK_DIR/issuer-pubkey.pem" \
                    -signature "$WORK_DIR/signature.bin" "$WORK_DIR/tbs.der" > /dev/null 2>&1; then
                RESULT=0
            fi
        fi
    fi

    rm -rf "$WORK_DIR"

    return $RESULT
}

# reduces a list of certificates to those that no other certificate of the list has signed, which
# leaves the rootCAs; duplicates are dropped by their fingerprint
function filter_root_certificates() {
    local CANDIDATES=("$@")
    local FINGERPRINTS=() UNIQUE=() ROOTS=()
    local CERT ISSUER FINGERPRINT IS_LEAF

    for CERT in "${CANDIDATES[@]}"; do
        FINGERPRINT="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"

        # skip files that are no certificate at all and every fingerprint seen before
        if [[ -z "$FINGERPRINT" || " ${FINGERPRINTS[*]} " == *" $FINGERPRINT "* ]]; then
            continue
        fi

        FINGERPRINTS+=("$FINGERPRINT")
        UNIQUE+=("$CERT")
    done

    for CERT in "${UNIQUE[@]}"; do
        IS_LEAF=0

        for ISSUER in "${UNIQUE[@]}"; do
            if [[ "$ISSUER" == "$CERT" ]]; then
                continue
            fi

            if is_signed_by "$CERT" "$ISSUER"; then
                IS_LEAF=1
                break
            fi
        done

        if [[ 0 == "$IS_LEAF" ]]; then
            ROOTS+=("$CERT")
        fi
    done

    if [[ 0 -eq ${#ROOTS[@]} ]]; then
        return
    fi

    printf '%s\n' "${ROOTS[@]}"
}

# detects the trust store of this machine and prints it as "<target directory><tab><update command>";
# returns 1, if the distribution is unknown
function detect_host_trust_store() {
    local DISTRO DISTRO_LIKE CANDIDATE

    # both are read in a subshell, so /etc/os-release does not leak its variables into this script
    DISTRO="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
    DISTRO_LIKE="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}")"

    if [[ -z "$DISTRO" && -f /etc/alpine-release ]]; then
        DISTRO="alpine"
    fi

    # the ID of a derivative is tested first, its ID_LIKE list serves as a fallback
    for CANDIDATE in $DISTRO $DISTRO_LIKE; do
        case "$CANDIDATE" in
            ubuntu|debian|linuxmint|pop|raspbian|alpine)
                printf '%s\t%s' '/usr/local/share/ca-certificates' 'update-ca-certificates'
                return 0
                ;;
            fedora|rhel|centos|rocky|almalinux|ol)
                printf '%s\t%s' '/etc/pki/ca-trust/source/anchors' 'update-ca-trust extract'
                return 0
                ;;
            arch|manjaro|endeavouros)
                printf '%s\t%s' '/etc/ca-certificates/trust-source/anchors' 'trust extract-compat'
                return 0
                ;;
        esac
    done

    return 1
}

# copies a rootCA into the trust store of this machine, so curl, git and every other tool on the host
# accept the certificates issued for docker.test; this needs root permissions
function install_rootca_on_host() {
    local ROOTCA_CRT=$1
    local TRUST_STORE TARGET_DIR UPDATE_COMMAND TARGET_FILE
    local SUDO_COMMAND=""

    if [[ ! -f "$ROOTCA_CRT" ]]; then
        print_error "Could not find the certificate $ROOTCA_CRT." 1
        return 1
    fi

    if ! TRUST_STORE="$(detect_host_trust_store)"; then
        print_warning "Could not detect the trust store of this machine, so $ROOTCA_CRT has to be installed manually." 1
        return 1
    fi

    IFS=$'\t' read -r TARGET_DIR UPDATE_COMMAND <<< "$TRUST_STORE"
    TARGET_FILE="$TARGET_DIR/docker-proxy-stack-$(basename "$ROOTCA_CRT")"

    if [[ 0 != "$EUID" ]]; then
        if ! command -v sudo > /dev/null 2>&1; then
            print_error "Installing a rootCA needs root permissions, but sudo is not available on this machine." 1
            return 1
        fi

        SUDO_COMMAND="sudo"
    fi

    print_info "Installing $ROOTCA_CRT as $TARGET_FILE, which needs root permissions."

    # -L resolves symlinks, as the trust store needs the certificate itself
    if ! ${SUDO_COMMAND} mkdir -p "$TARGET_DIR" || ! ${SUDO_COMMAND} cp -L "$ROOTCA_CRT" "$TARGET_FILE"; then
        print_error "Could not copy $ROOTCA_CRT to $TARGET_FILE." 1
        return 1
    fi

    ${SUDO_COMMAND} chmod 644 "$TARGET_FILE"

    if ! ${SUDO_COMMAND} ${UPDATE_COMMAND}; then
        print_error "The command '$UPDATE_COMMAND' failed, so the rootCA is not trusted, yet." 1
        return 1
    fi

    print_info "The rootCA is now part of the trust store of this machine." 1
}

# asks whether a rootCA shall be installed into the trust store of this machine and does so on approval;
# a rootCA that is already installed with the very same content is skipped without a question
function offer_rootca_installation() {
    local ROOTCA_CRT=$1
    local TRUST_STORE TARGET_DIR UPDATE_COMMAND TARGET_FILE
    local NEW_FINGERPRINT INSTALLED_FINGERPRINT

    if [[ ! -f "$ROOTCA_CRT" ]]; then
        return 1
    fi

    if ! TRUST_STORE="$(detect_host_trust_store)"; then
        print_warning "Could not detect the trust store of this machine, so $ROOTCA_CRT has to be installed manually." 1
        return 1
    fi

    IFS=$'\t' read -r TARGET_DIR UPDATE_COMMAND <<< "$TRUST_STORE"
    TARGET_FILE="$TARGET_DIR/docker-proxy-stack-$(basename "$ROOTCA_CRT")"

    # an unchanged rootCA is already trusted, there is nothing to ask for
    if [[ -f "$TARGET_FILE" ]]; then
        NEW_FINGERPRINT="$(openssl x509 -in "$ROOTCA_CRT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
        INSTALLED_FINGERPRINT="$(openssl x509 -in "$TARGET_FILE" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"

        if [[ -n "$NEW_FINGERPRINT" && "$NEW_FINGERPRINT" == "$INSTALLED_FINGERPRINT" ]]; then
            print_info "This rootCA is already installed in the trust store of this machine ($TARGET_FILE)." 1
            return 0
        fi

        print_warning "An older version of this rootCA is installed in the trust store of this machine ($TARGET_FILE)."
    fi

    print_info "The rootCA may be installed in the trust store of this machine, so curl, git, composer etc. accept the certificates for docker.test."

    if ! match_confirmation_or_default "Install $(basename "$ROOTCA_CRT") into $TARGET_DIR now? [y/N] " "n"; then
        print_info "Skipped. You can install it manually anytime:"
        print_info "    sudo cp $ROOTCA_CRT $TARGET_FILE"
        print_info "    sudo $UPDATE_COMMAND" 1

        return 0
    fi

    install_rootca_on_host "$ROOTCA_CRT"
}

function copy_certs_to_container() {
    local CONTAINER CONTAINER_NAME DISTRO DISTRO_FAMILY CERT_TARGET_DIR CERT_FILES TRUSTED_CERTS filename

    CONTAINER=$1
    CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$CONTAINER" 2>/dev/null | sed 's|^/||')

    if ! docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q "true"; then
        print_error "Container '$CONTAINER' is not existing or not running." 1
        return
    fi

    DISTRO=$(detect_distro "$CONTAINER")

    case "$DISTRO" in
        ubuntu|debian|linuxmint|pop)
            DISTRO_FAMILY="debian"
            CERT_TARGET_DIR="/usr/local/share/ca-certificates"
            ;;
        alpine)
            DISTRO_FAMILY="alpine"
            CERT_TARGET_DIR="/usr/local/share/ca-certificates"
            ;;
        fedora|rhel|centos|rocky|almalinux|ol)
            DISTRO_FAMILY="rhel"
            CERT_TARGET_DIR="/etc/pki/ca-trust/source/anchors"
            ;;
        *)
            print_error "Distro '$DISTRO' is not supported." 1
            return
            ;;
    esac

    # collect .crt files from directory (including symlinks pointing to valid files, e.g. from Let's Encrypt companion)
    mapfile -t CERT_FILES < <(find -L "$CERTS_PATH" -maxdepth 1 -type f -name "*.crt")

    if [[ ${#CERT_FILES[@]} -eq 0 ]]; then
        print_error "No .crt files located in: ${CERTS_PATH}" 1
        return
    fi

    # only the rootCAs belong into a trust store; host certificates are verified through their issuer
    mapfile -t TRUSTED_CERTS < <(filter_root_certificates "${CERT_FILES[@]}")

    if [[ ${#TRUSTED_CERTS[@]} -eq 0 ]]; then
        print_warning "Could not tell rootCAs and host certificates apart in ${CERTS_PATH}. Installing all certificates instead."
        TRUSTED_CERTS=("${CERT_FILES[@]}")
    fi

    # create the destination certs directory and copy files into
    docker exec --user root "$CONTAINER" sh -c "mkdir -p '$CERT_TARGET_DIR'"

    for cert in "${TRUSTED_CERTS[@]}"; do
        filename="$(basename "${cert}")"
        real_cert="$(readlink -f "${cert}")"
        docker cp "$real_cert" "$CONTAINER:$CERT_TARGET_DIR/$filename" > /dev/null
        docker exec --user root "$CONTAINER" sh -c "chmod 644 '$CERT_TARGET_DIR/$filename'"
    done

    case "$DISTRO_FAMILY" in
        debian|alpine)
            case "$DISTRO_FAMILY" in
                debian)
                    docker exec "$CONTAINER" sh -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null 2>&1 && \
                        apt-get install -y -qq ca-certificates > /dev/null 2>&1"
                    ;;
                alpine)
                    docker exec "$CONTAINER" sh -c "apk add --no-cache ca-certificates > /dev/null 2>&1"
                    ;;
            esac
            docker exec "$CONTAINER" sh -c "update-ca-certificates > /dev/null 2>&1"
            ;;
        rhel)
            docker exec "$CONTAINER" sh -c "
                if command -v dnf >/dev/null 2>&1; then
                    dnf install -y -q ca-certificates > /dev/null 2>&1
                else
                    yum install -y -q ca-certificates > /dev/null 2>&1
                fi
            "
            docker exec "$CONTAINER" sh -c "update-ca-trust extract > /dev/null 2>&1"
            ;;
    esac

    print_info "Installed certificates to container '${CONTAINER_NAME:-$CONTAINER}'."
}

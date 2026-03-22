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

function copy_certs_to_container() {
    local CONTAINER DISTRO DISTRO_FAMILY CERT_TARGET_DIR CERT_FILES filename

    CONTAINER=$1

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

    # collect .crt files from directory
    mapfile -t CERT_FILES < <(find "$CERTS_PATH" -maxdepth 1 -type f -name "*.crt")

    if [[ ${#CERT_FILES[@]} -eq 0 ]]; then
        print_error "Keine .crt-Dateien gefunden in: ${CERT_SOURCE_DIR}" 1
        return
    fi

    # create the destination certs directory and copy files into
    docker exec "$CONTAINER" sh -c "mkdir -p '$CERT_TARGET_DIR'"

    for cert in "${CERT_FILES[@]}"; do
        filename="$(basename "${cert}")"
        docker cp "$cert" "$CONTAINER:$CERT_TARGET_DIR/$filename" > /dev/null
        docker exec "$CONTAINER" sh -c "chmod 644 '$CERT_TARGET_DIR/$filename'"
    done

    case "$DISTRO_FAMILY" in
        debian|alpine)
            case "$DISTRO_FAMILY" in
                debian)
                    docker exec "$CONTAINER" sh -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
                        apt-get install -y -qq ca-certificates 2>&1 > /dev/null | grep -v 'debconf'"
                    ;;
                alpine)
                    docker exec "$CONTAINER" sh -c "apk add --no-cache ca-certificates 2>&1 > /dev/null"
                    ;;
            esac
            docker exec "$CONTAINER" sh -c "update-ca-certificates 2>&1 > /dev/null"
            ;;
        rhel)
            docker exec "$CONTAINER" sh -c "
                if command -v dnf >/dev/null 2>&1; then
                    dnf install -y -q ca-certificates 2>&1 > /dev/null
                else
                    yum install -y -q ca-certificates 2>&1 > /dev/null
                fi
            "
            docker exec "$CONTAINER" sh -c "update-ca-trust extract 2>&1 > /dev/null"
            ;;
    esac

    print_info "Installed certificates to container."
}

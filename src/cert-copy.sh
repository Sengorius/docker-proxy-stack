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
    local CONTAINER CONTAINER_NAME DISTRO DISTRO_FAMILY CERT_TARGET_DIR CERT_FILES filename

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
        print_error "No .crt files located in: ${CERT_SOURCE_DIR}" 1
        return
    fi

    # create the destination certs directory and copy files into
    docker exec --user root "$CONTAINER" sh -c "mkdir -p '$CERT_TARGET_DIR'"

    for cert in "${CERT_FILES[@]}"; do
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

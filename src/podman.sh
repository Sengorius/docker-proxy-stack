# as the NGINX proxy needs a socket to communicate; podman also provides a socket, but it
# is only accessible for root; here is a workaround
# see https://stackoverflow.com/a/77685096
function podman_enable_socket_for_current_user() {
    local SOCKET_PATH="$XDG_RUNTIME_DIR/podman/podman.sock"

    if [[ "$DE_ENGINE" == "podman" ]] && [[ ! -f "$SOCKET_PATH" ]]; then
        # if the file is not present, we need to enable the service via systemctl
        # TODO: this only works when systemctl is installed
        print_info "As the Podman socket is only accessible for root, we'll now create"
        print_info "a symlink for the current user." 1
        systemctl --user enable --now podman.socket > /dev/null 2>&1
    fi
}

# the main container needs to access port 80 + 443 on a system, which is prevented by default
# we need to allow this in systemctl config
function podman_allow_lower_ports() {
    local FILE_NAME="/etc/sysctl.d/59-unpriviledged-ports.conf"

    if [[ "$DE_ENGINE" == "podman" ]] && [[ ! -f "$FILE_NAME" ]]; then
        print_warning "Podman needs permission to start containers on port 80 and 443. Therefore it is"
        print_warning "necessary to update systemctl configuration with admin permission." 1

        CONTINUE=$(match_answer_or_default "Do you wish to continue? [N/y]: " "n")

        case $CONTINUE in
            [yY][eE][sS]|[yY])
                sudo true # sudo must be given
                echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee "$FILE_NAME" > /dev/null 2>&1
                print_info "Placed the file $FILE_NAME on your system." 1
                ;;
            *)
                print_error "Abborting." 1
                ;;
        esac
    fi
}

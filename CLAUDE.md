CLAUDE.md
=========

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Docker-Proxy-Stack** is a local web development toolkit built on 
[jwilder/nginx-proxy](https://github.com/nginx-proxy/nginx-proxy). It provides HTTPS termination, domain routing 
(e.g., `https://project.docker.test`), certificate distribution, and shared infrastructure (databases, mail, etc.) 
across all local projects via a single Docker network (`proxy-network`).

The main CLI is `./DockerExec` — a Bash script that orchestrates container lifecycle, hosts file management, SSL 
certificates, and spawn containers.

## Common Commands

```bash
# Proxy stack lifecycle
./DockerExec proxy init                     # Start proxy network + all enabled spawns
./DockerExec proxy finish                   # Shut down entire proxy stack

# Project containers (run from project directory)
./DockerExec proxy start [compose-file]     # Start project, update hosts + certs
./DockerExec proxy stop [compose-file]      # Stop project, clean hosts entries

# Spawn management (global services like databases, mail)
./DockerExec spawn status                   # List available & enabled spawns
./DockerExec spawn enable <name> [priority]
./DockerExec spawn disable <name>
./DockerExec spawn create                   # Interactive spawn creation wizard

# Certificates
./DockerExec do init-certs                  # Generate root CA + wildcard cert for docker.test
./DockerExec do add-cert                    # Add multilevel wildcard cert (e.g., *.sub.docker.test)

# Utilities
./DockerExec do ps                          # Docker ps with configured columns
./DockerExec do images                      # Docker images shortcut
./DockerExec do cleanup                     # Remove dangling images
./DockerExec do self-update                 # Pull latest version via git

# Project template generation
./DockerExec proxy generate [domain] # Scaffold docker-compose.proxy.yaml for a new project
```

## Architecture

### Source Modules (`src/`)
The `DockerExec` script sources all modules at startup:
- **`main.sh`** — Core logic: starting/stopping containers, updating `/etc/hosts` inside containers, certificate 
  distribution coordination
- **`spawns.sh`** — Spawn CRUD: enable/disable via symlinks, priority ordering, script generation
- **`helpers.sh`** — Shared utilities: docker-compose detection, DB import, update checks
- **`generate.sh`** — Project scaffolding and `openssl` certificate generation
- **`cert-copy.sh`** — Copies certs into running containers; detects distro (Debian/Ubuntu, Alpine, RHEL family) and 
  runs the appropriate trust store update command
- **`warnings.sh`** — ANSI-colored `print_error`, `print_info`, `print_warning`
- **`security.sh`** — File existence validation

### Spawn System
Spawns are plain `docker run` shell scripts (not compose), stored in `spawns-available/`. Enabling a spawn creates a 
symlink in `spawns-enabled/` with a numeric priority prefix (e.g., `010-adminer`). On `proxy init`, enabled spawns are 
started in ascending priority order. The proxy-main container is always `000-main`.

### Hosts File Management
A temporary file `.current-hosts` is used as an accumulator. When containers start, their IPs and `VIRTUAL_HOST` 
values are collected into this file, then atomically pushed into every running container's `/etc/hosts`. Managed 
entries are bracketed by `### DockerExec hosts file update ###` markers.

### Certificate Flow
1. Root CA + domain certs live in `certs/`
2. On project start, `copy_certs_to_container()` in `cert-copy.sh` detects the container OS and installs certs into 
   the appropriate system trust store
3. Users register `rootCA.crt` in their browser once; all `*.docker.test` subdomains then work with HTTPS

### Configuration (`.env`)
Key variables that control behavior:
- `WEB_CONTAINER_SUFFIXES` / `APP_CONTAINER_SUFFIXES` — used to identify which containers to update
- `NETWORK_NAME` — Docker network all proxy-connected containers join
- `ATTACH_TO_COMPOSE_LOGS` — whether to tail logs after `proxy start`
- `DOCKER_PS_COLUMNS` / `DOCKER_IMAGES_COLUMNS` — display columns for `do ps` / `do images`

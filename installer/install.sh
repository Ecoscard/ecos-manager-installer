#!/usr/bin/env bash
#
# ECOS Manager - Customer Bootstrap Installer
#
# Purpose:
#   1. Authenticate with the private ECOS release repository.
#   2. Download and verify the latest (or requested) ECOS Manager release.
#   3. Install the Manager under /opt/ecos-manager.
#   4. Store the customer access token securely in /etc/ecos/credentials.
#   5. Show the Project Bundles available to the customer.
#   6. Let the customer choose a product, install it and activate it.
#   7. Run ECOS Doctor as the final validation.
#
# Distribution repository:
#   Ecoscard/ecos-manager-releases (private)
#
# Required customer token permission:
#   Repository: Ecoscard/ecos-manager-releases
#   Contents: Read-only
#
# Typical use:
#   chmod +x install.sh
#   sudo ./install.sh
#
# Automation examples:
#   sudo ECOS_GITHUB_TOKEN='...' ./install.sh --project ecos-vhsm
#   sudo ECOS_GITHUB_TOKEN='...' ./install.sh --manager-only
#

set -Eeuo pipefail
umask 077

readonly INSTALLER_VERSION="1.0.0"
readonly ECOS_RELEASE_OWNER="Ecoscard"
readonly ECOS_RELEASE_REPO="ecos-manager-releases"
readonly GITHUB_API="https://api.github.com"
readonly GITHUB_API_VERSION="2026-03-10"

readonly INSTALL_DIR="/opt/ecos-manager"
readonly PREVIOUS_DIR="/opt/ecos-manager.previous"
readonly GLOBAL_BIN="/usr/local/bin/ecos"
readonly CONFIG_DIR="/etc/ecos"
readonly STATE_DIR="/var/lib/ecos"
readonly CREDENTIALS_FILE="/etc/ecos/credentials"

REQUESTED_VERSION="latest"
REQUESTED_PROJECT=""
MANAGER_ONLY=0
SKIP_DOCTOR=0
FORCE_TOKEN=0

TOKEN=""
WORK_DIR=""
STAGING_DIR=""
AUTH_JSON_CONFIG=""
AUTH_ASSET_CONFIG=""
RELEASE_JSON=""

RELEASE_TAG=""
RELEASE_VERSION=""
PACKAGE_NAME=""
PACKAGE_API_URL=""
CHECKSUM_NAME=""
CHECKSUM_API_URL=""

SELECTED_PROJECT=""
SELECTED_PROJECT_VERSION=""
AVAILABLE_PROJECT_IDS=()
AVAILABLE_PROJECT_VERSIONS=()

info() {
    printf '[INFO] %s\n' "$*"
}

ok() {
    printf '[OK]   %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

fail() {
    printf '[FAIL] %s\n' "$*" >&2
}

die() {
    fail "$*"
    exit 1
}

cleanup() {
    TOKEN=""

    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi

    if [[ -n "${STAGING_DIR:-}" && -d "${STAGING_DIR}" ]]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup EXIT
trap 'die "Installation interrupted."' INT TERM

print_banner() {
    cat <<EOF_BANNER

============================================================
 ECOS Manager Installer
 Installer version: ${INSTALLER_VERSION}
============================================================

This installer will:
  - validate the ECOS Access Token;
  - install/update ECOS Manager;
  - list private ECOS products available for installation;
  - optionally install and activate the selected product;
  - run ECOS Doctor at the end.

EOF_BANNER
}

usage() {
    cat <<'USAGE'
ECOS Manager Installer

Usage:
  sudo ./install.sh
  sudo ./install.sh --project ecos-vhsm
  sudo ./install.sh --manager-only
  sudo ./install.sh --version 2.3.3

Options:
  --version VERSION   Install a specific ECOS Manager version.
                      Default: latest stable Manager release.

  --project ID        Install and activate this Project Bundle after
                      installing ECOS Manager. Useful for automation.

  --manager-only      Install ECOS Manager only. Do not ask for or
                      install a Project Bundle.

  --skip-doctor       Do not run "ecos doctor" after product activation.

  --force-token       Ignore an existing /etc/ecos/credentials file and
                      request a new ECOS Access Token.

  -h, --help          Show this help.

Authentication:
  Interactive installation securely asks for the ECOS Access Token
  supplied by ECOSCARD.

  For automation, set:
    ECOS_GITHUB_TOKEN

  The token must have access only to:
    Ecoscard/ecos-manager-releases

  Minimum repository permission:
    Contents: Read-only

Security:
  The validated token is stored in:
    /etc/ecos/credentials

  Owner: root:root
  Mode:  600
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                [[ $# -ge 2 ]] || die "--version requires a value."
                REQUESTED_VERSION="$2"
                shift 2
                ;;
            --project)
                [[ $# -ge 2 ]] || die "--project requires a Project Bundle ID."
                REQUESTED_PROJECT="$2"
                shift 2
                ;;
            --manager-only)
                MANAGER_ONLY=1
                shift
                ;;
            --skip-doctor)
                SKIP_DOCTOR=1
                shift
                ;;
            --force-token)
                FORCE_TOKEN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done

    if [[ "${REQUESTED_VERSION}" != "latest" ]]; then
        REQUESTED_VERSION="${REQUESTED_VERSION#v}"
        [[ "${REQUESTED_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
            || die "Invalid Manager version: ${REQUESTED_VERSION}"
    fi

    if [[ -n "${REQUESTED_PROJECT}" ]]; then
        [[ "${REQUESTED_PROJECT}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
            || die "Invalid Project Bundle ID: ${REQUESTED_PROJECT}"
    fi

    if [[ "${MANAGER_ONLY}" -eq 1 && -n "${REQUESTED_PROJECT}" ]]; then
        die "--manager-only and --project cannot be used together."
    fi
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Run this installer as root, for example: sudo ./install.sh"
    fi
}

install_dependencies() {
    local missing=()
    local cmd

    for cmd in curl tar sha256sum python3 awk sed grep mktemp; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi

    info "Installing required dependencies: ${missing[*]}"

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl tar coreutils python3 gawk grep sed
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl tar coreutils python3 gawk grep sed
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl tar coreutils python3 gawk grep sed
    else
        die "Missing dependencies (${missing[*]}) and no supported package manager was found."
    fi

    for cmd in curl tar sha256sum python3 awk sed grep mktemp; do
        command -v "${cmd}" >/dev/null 2>&1 \
            || die "Required command is still unavailable after dependency installation: ${cmd}"
    done
}

read_existing_token() {
    local stored=""

    [[ "${FORCE_TOKEN}" -eq 0 ]] || return 1
    [[ -r "${CREDENTIALS_FILE}" ]] || return 1

    stored="$(sed -n 's/^ECOS_GITHUB_TOKEN=//p' "${CREDENTIALS_FILE}" | head -n 1)"
    [[ -n "${stored}" ]] || return 1

    TOKEN="${stored}"
    info "Using the ECOS credential already configured on this server."
    return 0
}

read_token() {
    if [[ -n "${ECOS_GITHUB_TOKEN:-}" ]]; then
        TOKEN="${ECOS_GITHUB_TOKEN}"
        info "Using ECOS Access Token from ECOS_GITHUB_TOKEN."
        return
    fi

    if read_existing_token; then
        return
    fi

    [[ -r /dev/tty ]] \
        || die "No interactive terminal is available. Set ECOS_GITHUB_TOKEN for non-interactive installation."

    printf '\nECOS Access Token: ' > /dev/tty
    IFS= read -r -s TOKEN < /dev/tty
    printf '\n\n' > /dev/tty

    [[ -n "${TOKEN}" ]] || die "No ECOS Access Token was provided."
}

prepare_workdir() {
    WORK_DIR="$(mktemp -d /tmp/ecos-manager-installer.XXXXXX)"
    chmod 700 "${WORK_DIR}"

    AUTH_JSON_CONFIG="${WORK_DIR}/curl-json.conf"
    AUTH_ASSET_CONFIG="${WORK_DIR}/curl-asset.conf"

    cat > "${AUTH_JSON_CONFIG}" <<EOF_JSON
silent
show-error
location
fail
connect-timeout = 20
retry = 3
retry-delay = 2
header = "Authorization: Bearer ${TOKEN}"
header = "Accept: application/vnd.github+json"
header = "X-GitHub-Api-Version: ${GITHUB_API_VERSION}"
header = "User-Agent: ECOS-Manager-Installer/${INSTALLER_VERSION}"
EOF_JSON

    cat > "${AUTH_ASSET_CONFIG}" <<EOF_ASSET
silent
show-error
location
fail
connect-timeout = 20
retry = 3
retry-delay = 2
header = "Authorization: Bearer ${TOKEN}"
header = "Accept: application/octet-stream"
header = "X-GitHub-Api-Version: ${GITHUB_API_VERSION}"
header = "User-Agent: ECOS-Manager-Installer/${INSTALLER_VERSION}"
EOF_ASSET

    chmod 600 "${AUTH_JSON_CONFIG}" "${AUTH_ASSET_CONFIG}"
}

validate_repository_access() {
    local repo_json="${WORK_DIR}/repository.json"
    local url="${GITHUB_API}/repos/${ECOS_RELEASE_OWNER}/${ECOS_RELEASE_REPO}"

    info "Validating ECOS Access Token..."

    if ! curl --config "${AUTH_JSON_CONFIG}" --output "${repo_json}" "${url}"; then
        cat >&2 <<EOF_ERROR

[FAIL] Unable to access the private ECOS release repository.

Check that:
  - the ECOS Access Token is valid and has not expired;
  - it has access to ${ECOS_RELEASE_OWNER}/${ECOS_RELEASE_REPO};
  - repository permission is "Contents: Read-only";
  - organization approval was completed when required.
EOF_ERROR
        exit 1
    fi

    ok "ECOS Access Token validated."
}

fetch_release_metadata() {
    local release_url
    RELEASE_JSON="${WORK_DIR}/release.json"

    if [[ "${REQUESTED_VERSION}" == "latest" ]]; then
        release_url="${GITHUB_API}/repos/${ECOS_RELEASE_OWNER}/${ECOS_RELEASE_REPO}/releases/latest"
        info "Looking up the latest official ECOS Manager release..."
    else
        release_url="${GITHUB_API}/repos/${ECOS_RELEASE_OWNER}/${ECOS_RELEASE_REPO}/releases/tags/v${REQUESTED_VERSION}"
        info "Looking up ECOS Manager v${REQUESTED_VERSION}..."
    fi

    curl --config "${AUTH_JSON_CONFIG}" \
        --output "${RELEASE_JSON}" \
        "${release_url}" \
        || die "Unable to retrieve ECOS Manager release metadata."
}

resolve_release_assets() {
    local metadata_file="${WORK_DIR}/resolved-assets.txt"
    local -a release_data=()

    python3 - "${RELEASE_JSON}" > "${metadata_file}" <<'PY'
import json
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    release = json.load(f)

tag = release.get("tag_name", "")
if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?", tag):
    raise SystemExit(f"Unexpected Manager release tag: {tag!r}")

version = tag[1:]
package_name = f"ecos-manager-v{version}.tar.gz"
checksum_name = f"{package_name}.sha256"

assets = {
    item.get("name"): item.get("url")
    for item in release.get("assets", [])
    if item.get("name") and item.get("url")
}

missing = [name for name in (package_name, checksum_name) if name not in assets]
if missing:
    raise SystemExit("Required release asset(s) not found: " + ", ".join(missing))

print(tag)
print(version)
print(package_name)
print(assets[package_name])
print(checksum_name)
print(assets[checksum_name])
PY

    mapfile -t release_data < "${metadata_file}"
    [[ ${#release_data[@]} -eq 6 ]] || die "Unable to resolve release assets."

    RELEASE_TAG="${release_data[0]}"
    RELEASE_VERSION="${release_data[1]}"
    PACKAGE_NAME="${release_data[2]}"
    PACKAGE_API_URL="${release_data[3]}"
    CHECKSUM_NAME="${release_data[4]}"
    CHECKSUM_API_URL="${release_data[5]}"

    ok "Selected ECOS Manager ${RELEASE_VERSION}."
}

download_asset() {
    local api_url="$1"
    local destination="$2"

    curl --config "${AUTH_ASSET_CONFIG}" \
        --output "${destination}" \
        "${api_url}"
}

download_and_verify() {
    local package_path="${WORK_DIR}/${PACKAGE_NAME}"
    local checksum_path="${WORK_DIR}/${CHECKSUM_NAME}"

    info "Downloading ${PACKAGE_NAME}..."
    download_asset "${PACKAGE_API_URL}" "${package_path}" \
        || die "Failed to download ${PACKAGE_NAME}."

    info "Downloading ${CHECKSUM_NAME}..."
    download_asset "${CHECKSUM_API_URL}" "${checksum_path}" \
        || die "Failed to download ${CHECKSUM_NAME}."

    info "Verifying ECOS Manager SHA-256..."

    (
        cd "${WORK_DIR}"
        sha256sum -c "${CHECKSUM_NAME}"
    ) || die "SHA-256 verification failed. The package will not be installed."

    ok "ECOS Manager package integrity verified."
}

validate_archive() {
    local package_path="${WORK_DIR}/${PACKAGE_NAME}"

    info "Validating ECOS Manager release archive..."

    python3 - "${package_path}" <<'PY'
import pathlib
import sys
import tarfile

archive = sys.argv[1]

with tarfile.open(archive, "r:gz") as tf:
    members = tf.getmembers()
    if not members:
        raise SystemExit("Release archive is empty.")

    for member in members:
        name = member.name
        p = pathlib.PurePosixPath(name)

        if p.is_absolute() or ".." in p.parts:
            raise SystemExit(f"Unsafe archive path: {name}")

        if not (name == "ecos-manager" or name.startswith("ecos-manager/")):
            raise SystemExit(f"Unexpected archive entry: {name}")

        if member.isdev() or member.isfifo():
            raise SystemExit(f"Unsupported special file in archive: {name}")

        if member.issym() or member.islnk():
            link = pathlib.PurePosixPath(member.linkname)
            if link.is_absolute() or ".." in link.parts:
                raise SystemExit(f"Unsafe archive link: {name} -> {member.linkname}")

required = {
    "ecos-manager/bin/ecos",
    "ecos-manager/config/endpoints.conf",
}
actual = {m.name.rstrip("/") for m in members}
missing = sorted(required - actual)
if missing:
    raise SystemExit("Release archive is missing required file(s): " + ", ".join(missing))
PY

    ok "Release archive validated."
}

set_executable_permissions() {
    local root="$1"

    chmod +x "${root}/bin/ecos"

    [[ -f "${root}/install.sh" ]] && chmod +x "${root}/install.sh"
    [[ -f "${root}/offline/install-offline.sh" ]] && chmod +x "${root}/offline/install-offline.sh"

    if [[ -d "${root}/projects" ]]; then
        find "${root}/projects" \
            -type f \
            -path "*/hooks/*.sh" \
            -exec chmod +x {} \;
    fi
}

rollback_installation() {
    warn "The new ECOS Manager installation failed validation. Restoring the previous installation."

    rm -rf "${INSTALL_DIR}"

    if [[ -d "${PREVIOUS_DIR}" ]]; then
        mv "${PREVIOUS_DIR}" "${INSTALL_DIR}"
        ln -sfn "${INSTALL_DIR}/bin/ecos" "${GLOBAL_BIN}"
        warn "Previous ECOS Manager installation restored."
    else
        rm -f "${GLOBAL_BIN}"
    fi
}

install_manager() {
    local package_path="${WORK_DIR}/${PACKAGE_NAME}"

    STAGING_DIR="$(mktemp -d /opt/.ecos-manager.install.XXXXXX)"
    chmod 700 "${STAGING_DIR}"

    info "Extracting ECOS Manager ${RELEASE_VERSION}..."

    tar -xzf "${package_path}" \
        --no-same-owner \
        -C "${STAGING_DIR}"

    [[ -f "${STAGING_DIR}/ecos-manager/bin/ecos" ]] \
        || die "Release archive does not contain ecos-manager/bin/ecos."

    [[ -f "${STAGING_DIR}/ecos-manager/config/endpoints.conf" ]] \
        || die "Release archive does not contain config/endpoints.conf."

    set_executable_permissions "${STAGING_DIR}/ecos-manager"

    mkdir -p "${CONFIG_DIR}" "${STATE_DIR}"
    chmod 755 "${CONFIG_DIR}" "${STATE_DIR}"

    if [[ -e "${PREVIOUS_DIR}" ]]; then
        rm -rf "${PREVIOUS_DIR}"
    fi

    if [[ -d "${INSTALL_DIR}" ]]; then
        info "Preserving current ECOS Manager at ${PREVIOUS_DIR}..."
        mv "${INSTALL_DIR}" "${PREVIOUS_DIR}"
    fi

    if ! mv "${STAGING_DIR}/ecos-manager" "${INSTALL_DIR}"; then
        rollback_installation
        die "Unable to place ECOS Manager in ${INSTALL_DIR}."
    fi

    chown -R root:root "${INSTALL_DIR}"
    chmod 644 "${INSTALL_DIR}/config/endpoints.conf"
    ln -sfn "${INSTALL_DIR}/bin/ecos" "${GLOBAL_BIN}"

    STAGING_DIR=""

    info "Validating installed ECOS Manager..."

    if ! "${GLOBAL_BIN}" version; then
        rollback_installation
        die "Installed ECOS Manager failed its version validation."
    fi

    if ! grep -q '^ECOS_RELEASE_PROVIDER="github"$' "${INSTALL_DIR}/config/endpoints.conf"; then
        rollback_installation
        die "Installed Manager has an invalid private release configuration."
    fi

    ok "ECOS Manager ${RELEASE_VERSION} installed."
}

save_credentials() {
    local tmp

    [[ -n "${TOKEN}" ]] || die "Cannot persist an empty ECOS Access Token."

    mkdir -p "${CONFIG_DIR}"
    chmod 755 "${CONFIG_DIR}"

    umask 077
    tmp="$(mktemp "${CONFIG_DIR}/.credentials.XXXXXX")"

    printf 'ECOS_GITHUB_TOKEN=%s\n' "${TOKEN}" > "${tmp}"
    chown root:root "${tmp}"
    chmod 600 "${tmp}"
    mv "${tmp}" "${CREDENTIALS_FILE}"

    ok "ECOS access credential stored securely in ${CREDENTIALS_FILE}."
}

validate_installed_auth() {
    info "Validating installed ECOS authentication..."

    if ! "${GLOBAL_BIN}" auth status; then
        die "ECOS Manager was installed, but private repository authentication failed."
    fi

    ok "Private ECOS repository authentication is working."
}

load_available_projects() {
    local output
    local line
    local id
    local version

    AVAILABLE_PROJECT_IDS=()
    AVAILABLE_PROJECT_VERSIONS=()

    info "Looking up available ECOS products..."

    if ! output="$("${GLOBAL_BIN}" project available 2>&1)"; then
        printf '%s\n' "${output}" >&2
        die "Unable to list available ECOS Project Bundles."
    fi

    printf '\n%s\n\n' "${output}"

    while IFS= read -r line; do
        id="$(awk '{print $1}' <<< "${line}")"
        version="$(awk '{print $2}' <<< "${line}")"

        [[ "${id}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || continue
        [[ "${id}" != "ID" ]] || continue
        [[ "${version}" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || continue

        AVAILABLE_PROJECT_IDS+=("${id}")
        AVAILABLE_PROJECT_VERSIONS+=("${version}")
    done <<< "${output}"

    if [[ ${#AVAILABLE_PROJECT_IDS[@]} -eq 0 ]]; then
        warn "No Project Bundles are currently available. ECOS Manager installation will finish without a product."
        return 1
    fi

    return 0
}

project_is_available() {
    local wanted="$1"
    local i

    for i in "${!AVAILABLE_PROJECT_IDS[@]}"; do
        if [[ "${AVAILABLE_PROJECT_IDS[$i]}" == "${wanted}" ]]; then
            SELECTED_PROJECT="${AVAILABLE_PROJECT_IDS[$i]}"
            SELECTED_PROJECT_VERSION="${AVAILABLE_PROJECT_VERSIONS[$i]}"
            return 0
        fi
    done

    return 1
}

select_project_interactively() {
    local choice=""
    local i
    local max

    max="${#AVAILABLE_PROJECT_IDS[@]}"

    cat > /dev/tty <<'EOF_MENU'
Choose the ECOS product to install now:
EOF_MENU

    for i in "${!AVAILABLE_PROJECT_IDS[@]}"; do
        printf '  %d) %s (%s)\n' \
            "$((i + 1))" \
            "${AVAILABLE_PROJECT_IDS[$i]}" \
            "${AVAILABLE_PROJECT_VERSIONS[$i]}" > /dev/tty
    done

    printf '  0) Finish with ECOS Manager only\n\n' > /dev/tty

    while true; do
        printf 'Selection [0-%d]: ' "${max}" > /dev/tty
        IFS= read -r choice < /dev/tty

        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= max )); then
            break
        fi

        printf 'Invalid selection. Try again.\n' > /dev/tty
    done

    if (( choice == 0 )); then
        SELECTED_PROJECT=""
        SELECTED_PROJECT_VERSION=""
        return
    fi

    SELECTED_PROJECT="${AVAILABLE_PROJECT_IDS[$((choice - 1))]}"
    SELECTED_PROJECT_VERSION="${AVAILABLE_PROJECT_VERSIONS[$((choice - 1))]}"
}

select_project() {
    if [[ "${MANAGER_ONLY}" -eq 1 ]]; then
        info "Manager-only installation requested."
        return
    fi

    if ! load_available_projects; then
        return
    fi

    if [[ -n "${REQUESTED_PROJECT}" ]]; then
        project_is_available "${REQUESTED_PROJECT}" \
            || die "Requested Project Bundle is not available: ${REQUESTED_PROJECT}"
        return
    fi

    if [[ ! -r /dev/tty ]]; then
        warn "No interactive terminal is available. Finishing with ECOS Manager only."
        warn "Use --project <id> for non-interactive product installation."
        return
    fi

    select_project_interactively
}

install_selected_project() {
    [[ -n "${SELECTED_PROJECT}" ]] || return

    printf '\n============================================================\n'
    printf ' Installing ECOS product\n'
    printf '============================================================\n'
    printf 'Project: %s\n' "${SELECTED_PROJECT}"
    printf 'Version: %s\n\n' "${SELECTED_PROJECT_VERSION}"

    "${GLOBAL_BIN}" project install "${SELECTED_PROJECT}" \
        || die "Project Bundle installation failed: ${SELECTED_PROJECT}"

    info "Activating Project Bundle: ${SELECTED_PROJECT}"
    "${GLOBAL_BIN}" use "${SELECTED_PROJECT}" \
        || die "Unable to activate Project Bundle: ${SELECTED_PROJECT}"

    ok "Project Bundle ${SELECTED_PROJECT} installed and activated."
}

run_doctor() {
    [[ "${SKIP_DOCTOR}" -eq 0 ]] || return
    [[ -n "${SELECTED_PROJECT}" ]] || return

    printf '\n============================================================\n'
    printf ' ECOS Doctor\n'
    printf '============================================================\n\n'

    if "${GLOBAL_BIN}" doctor; then
        ok "ECOS Doctor completed successfully."
    else
        warn "ECOS Doctor found items that still require configuration or attention."
        warn "This does not invalidate the ECOS Manager installation. Review the diagnostics above."
    fi
}

print_success() {
    local product_summary="Manager only"

    if [[ -n "${SELECTED_PROJECT}" ]]; then
        product_summary="${SELECTED_PROJECT} ${SELECTED_PROJECT_VERSION}"
    fi

    cat <<EOF_SUCCESS

============================================================
 ECOS installation completed
============================================================

ECOS Manager:      ${RELEASE_VERSION}
Installed product: ${product_summary}

Manager path:
  ${INSTALL_DIR}

Global command:
  ${GLOBAL_BIN}

Private credential:
  ${CREDENTIALS_FILE}
  owner root:root, mode 600

Useful commands:
  ecos version
  sudo ecos auth status
  sudo ecos project available
  ecos project list
  ecos doctor
  ecos status
  sudo ecos self-update

EOF_SUCCESS

    if [[ -n "${SELECTED_PROJECT}" ]]; then
        cat <<EOF_PRODUCT
The Project Bundle is installed and active.

If ECOS Doctor reported missing configuration, configure the required
items before starting the application stack. Typical commands include:

  sudo ecos config
  sudo ecos config hsm

When configuration is complete, follow the product deployment procedure
or use the ECOS Manager lifecycle commands appropriate to the project.

EOF_PRODUCT
    else
        cat <<'EOF_MANAGER_ONLY'
No product was installed during this run.

To install one later:

  sudo ecos project available
  sudo ecos project install <project>
  sudo ecos use <project>

EOF_MANAGER_ONLY
    fi

    cat <<'EOF_END'
Keep the ECOS Access Token private. Contact ECOSCARD support if access
needs to be replaced or revoked.
============================================================
EOF_END
}

main() {
    parse_args "$@"
    require_root
    print_banner
    install_dependencies
    read_token
    prepare_workdir
    validate_repository_access
    fetch_release_metadata
    resolve_release_assets
    download_and_verify
    validate_archive
    install_manager
    save_credentials
    validate_installed_auth
    select_project
    install_selected_project
    run_doctor
    print_success
}

main "$@"

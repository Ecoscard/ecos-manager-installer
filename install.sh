#!/usr/bin/env bash
#
# ECOS Manager Bootstrap Installer
#
# Downloads an official ECOS Manager release from the private
# Ecoscard/ecos-manager-releases GitHub repository, verifies SHA-256,
# and installs the Manager under /opt/ecos-manager.
#
# Authentication:
#   - Preferred: interactive prompt (token is not stored).
#   - Automation: ECOS_GITHUB_TOKEN environment variable.
#
# Required token permission:
#   Ecoscard/ecos-manager-releases -> Contents: Read
#

set -Eeuo pipefail
umask 077

readonly ECOS_RELEASE_OWNER="Ecoscard"
readonly ECOS_RELEASE_REPO="ecos-manager-releases"
readonly GITHUB_API="https://api.github.com"
readonly GITHUB_API_VERSION="2026-03-10"

readonly INSTALL_DIR="/opt/ecos-manager"
readonly PREVIOUS_DIR="/opt/ecos-manager.previous"
readonly GLOBAL_BIN="/usr/local/bin/ecos"
readonly CONFIG_DIR="/etc/ecos"
readonly STATE_DIR="/var/lib/ecos"

REQUESTED_VERSION="latest"
TOKEN=""
WORK_DIR=""
STAGING_DIR=""
AUTH_JSON_CONFIG=""
AUTH_ASSET_CONFIG=""
RELEASE_JSON=""

log() {
    printf '[ECOS] %s\n' "$*"
}

warn() {
    printf '[ECOS] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[ECOS] ERROR: %s\n' "$*" >&2
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

usage() {
    cat <<'USAGE'
ECOS Manager Installer

Usage:
  sudo ./install.sh
  sudo ./install.sh --version 2.0.1
  sudo ./install.sh --version v2.0.1

Options:
  --version VERSION   Install a specific ECOS Manager release.
                      Default: latest stable release.
  -h, --help          Show this help.

Authentication:
  By default, the installer securely asks for a GitHub token.

  For non-interactive automation, you may provide:
    ECOS_GITHUB_TOKEN

  The token must have read access to:
    Ecoscard/ecos-manager-releases

  Minimum repository permission:
    Contents: Read

Security:
  The token is used only during the download and is not persisted
  by this installer.
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

        if [[ ! "${REQUESTED_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
            die "Invalid version: ${REQUESTED_VERSION}"
        fi
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

    for cmd in curl tar sha256sum python3; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi

    log "Installing required dependencies: ${missing[*]}"

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl tar coreutils python3
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl tar coreutils python3
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl tar coreutils python3
    else
        die "Missing dependencies (${missing[*]}) and no supported package manager was found."
    fi

    for cmd in curl tar sha256sum python3; do
        command -v "${cmd}" >/dev/null 2>&1 \
            || die "Required command is still unavailable after dependency installation: ${cmd}"
    done
}

read_token() {
    if [[ -n "${ECOS_GITHUB_TOKEN:-}" ]]; then
        TOKEN="${ECOS_GITHUB_TOKEN}"
        log "Using GitHub credential from ECOS_GITHUB_TOKEN."
        return
    fi

    [[ -r /dev/tty ]] \
        || die "No interactive terminal is available. Set ECOS_GITHUB_TOKEN for non-interactive installation."

    printf '\nGitHub access token for ECOS Manager releases: ' > /dev/tty
    IFS= read -r -s TOKEN < /dev/tty
    printf '\n\n' > /dev/tty

    [[ -n "${TOKEN}" ]] || die "No GitHub token was provided."
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
header = "Authorization: Bearer ${TOKEN}"
header = "Accept: application/vnd.github+json"
header = "X-GitHub-Api-Version: ${GITHUB_API_VERSION}"
EOF_JSON

    cat > "${AUTH_ASSET_CONFIG}" <<EOF_ASSET
silent
show-error
location
fail
header = "Authorization: Bearer ${TOKEN}"
header = "Accept: application/octet-stream"
header = "X-GitHub-Api-Version: ${GITHUB_API_VERSION}"
EOF_ASSET

    chmod 600 "${AUTH_JSON_CONFIG}" "${AUTH_ASSET_CONFIG}"
}

fetch_release_metadata() {
    local release_url
    RELEASE_JSON="${WORK_DIR}/release.json"

    if [[ "${REQUESTED_VERSION}" == "latest" ]]; then
        release_url="${GITHUB_API}/repos/${ECOS_RELEASE_OWNER}/${ECOS_RELEASE_REPO}/releases/latest"
        log "Looking up the latest official ECOS Manager release..."
    else
        release_url="${GITHUB_API}/repos/${ECOS_RELEASE_OWNER}/${ECOS_RELEASE_REPO}/releases/tags/v${REQUESTED_VERSION}"
        log "Looking up ECOS Manager v${REQUESTED_VERSION}..."
    fi

    if ! curl --config "${AUTH_JSON_CONFIG}" \
        --output "${RELEASE_JSON}" \
        "${release_url}"; then
        cat >&2 <<EOF_ERROR

[ECOS] Unable to access the private release repository.

Check that:
  - the GitHub token is valid;
  - the token owner has access to ${ECOS_RELEASE_OWNER}/${ECOS_RELEASE_REPO};
  - the token has repository permission "Contents: Read";
  - if the token belongs to an organization, it has been approved when required.
EOF_ERROR
        exit 1
    fi

}

resolve_release_assets() {
    local release_json="$1"
    local metadata_file="${WORK_DIR}/resolved-assets.txt"

    python3 - "${release_json}" > "${metadata_file}" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    release = json.load(f)

tag = release.get("tag_name", "")
if not tag:
    raise SystemExit("Release metadata does not contain tag_name.")

version = tag[1:] if tag.startswith("v") else tag
package_name = f"ecos-manager-v{version}.tar.gz"
checksum_name = f"{package_name}.sha256"

assets = {
    item.get("name"): item.get("url")
    for item in release.get("assets", [])
    if item.get("name") and item.get("url")
}

missing = [name for name in (package_name, checksum_name) if name not in assets]
if missing:
    raise SystemExit(
        "Required release asset(s) not found: " + ", ".join(missing)
    )

print(tag)
print(version)
print(package_name)
print(assets[package_name])
print(checksum_name)
print(assets[checksum_name])
PY

    mapfile -t RELEASE_DATA < "${metadata_file}"

    [[ ${#RELEASE_DATA[@]} -eq 6 ]] \
        || die "Unable to resolve release assets."

    RELEASE_TAG="${RELEASE_DATA[0]}"
    RELEASE_VERSION="${RELEASE_DATA[1]}"
    PACKAGE_NAME="${RELEASE_DATA[2]}"
    PACKAGE_API_URL="${RELEASE_DATA[3]}"
    CHECKSUM_NAME="${RELEASE_DATA[4]}"
    CHECKSUM_API_URL="${RELEASE_DATA[5]}"

    log "Selected release: ${RELEASE_TAG}"
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

    log "Downloading ${PACKAGE_NAME}..."
    download_asset "${PACKAGE_API_URL}" "${package_path}" \
        || die "Failed to download ${PACKAGE_NAME}."

    log "Downloading ${CHECKSUM_NAME}..."
    download_asset "${CHECKSUM_API_URL}" "${checksum_path}" \
        || die "Failed to download ${CHECKSUM_NAME}."

    # Authentication is no longer needed after both files have been downloaded.
    TOKEN=""
    rm -f "${AUTH_JSON_CONFIG}" "${AUTH_ASSET_CONFIG}"

    log "Verifying SHA-256 checksum..."

    (
        cd "${WORK_DIR}"
        sha256sum -c "${CHECKSUM_NAME}"
    ) || die "SHA-256 verification failed. The package will not be installed."

    log "Checksum verified successfully."
}

validate_archive() {
    local package_path="${WORK_DIR}/${PACKAGE_NAME}"
    local invalid=""

    log "Validating release archive..."

    while IFS= read -r entry; do
        [[ -n "${entry}" ]] || continue

        case "${entry}" in
            ecos-manager|ecos-manager/*)
                ;;
            *)
                invalid="${entry}"
                break
                ;;
        esac

        if [[ "${entry}" == *"/../"* || "${entry}" == "../"* || "${entry}" == /* ]]; then
            invalid="${entry}"
            break
        fi
    done < <(tar -tzf "${package_path}")

    [[ -z "${invalid}" ]] \
        || die "Unsafe or unexpected archive entry: ${invalid}"
}

set_executable_permissions() {
    local root="$1"

    chmod +x "${root}/bin/ecos"

    [[ -f "${root}/install.sh" ]] \
        && chmod +x "${root}/install.sh"

    [[ -f "${root}/offline/install-offline.sh" ]] \
        && chmod +x "${root}/offline/install-offline.sh"

    if [[ -d "${root}/projects" ]]; then
        find "${root}/projects" \
            -type f \
            -path "*/hooks/*.sh" \
            -exec chmod +x {} \;
    fi
}

rollback_installation() {
    warn "The new installation failed validation. Restoring previous installation."

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

    log "Extracting ECOS Manager ${RELEASE_VERSION}..."

    tar -xzf "${package_path}" \
        --no-same-owner \
        -C "${STAGING_DIR}"

    [[ -f "${STAGING_DIR}/ecos-manager/bin/ecos" ]] \
        || die "The release archive does not contain ecos-manager/bin/ecos."

    set_executable_permissions "${STAGING_DIR}/ecos-manager"

    mkdir -p "${CONFIG_DIR}" "${STATE_DIR}"
    chmod 755 "${CONFIG_DIR}" "${STATE_DIR}"

    if [[ -e "${PREVIOUS_DIR}" ]]; then
        rm -rf "${PREVIOUS_DIR}"
    fi

    if [[ -d "${INSTALL_DIR}" ]]; then
        log "Preserving the current installation at ${PREVIOUS_DIR}..."
        mv "${INSTALL_DIR}" "${PREVIOUS_DIR}"
    fi

    if ! mv "${STAGING_DIR}/ecos-manager" "${INSTALL_DIR}"; then
        rollback_installation
        die "Unable to place ECOS Manager in ${INSTALL_DIR}."
    fi

    chown -R root:root "${INSTALL_DIR}"
    ln -sfn "${INSTALL_DIR}/bin/ecos" "${GLOBAL_BIN}"

    STAGING_DIR=""

    log "Validating installed ECOS Manager..."

    if ! "${GLOBAL_BIN}" version; then
        rollback_installation
        die "Installed ECOS Manager failed its validation check."
    fi
}

print_success() {
    cat <<EOF_SUCCESS

============================================================
 ECOS Manager ${RELEASE_VERSION} installed successfully
============================================================

Installation:
  ${INSTALL_DIR}

Global command:
  ${GLOBAL_BIN}

Configuration:
  ${CONFIG_DIR}

State:
  ${STATE_DIR}

A previous installation, when present, is preserved at:
  ${PREVIOUS_DIR}

Recommended next commands:

  ecos version
  ecos doctor
  ecos project list

To install the bundled ECOS VHSM project when ready:

  ecos install ecos-vhsm

The GitHub access token was not persisted by this installer.
============================================================
EOF_SUCCESS
}

main() {
    parse_args "$@"
    require_root
    install_dependencies
    read_token
    prepare_workdir

    fetch_release_metadata

    resolve_release_assets "${RELEASE_JSON}"
    download_and_verify
    validate_archive
    install_manager
    print_success
}

main "$@"

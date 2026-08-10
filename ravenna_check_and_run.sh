#!/usr/bin/env bash
set -Eeuo pipefail

# Portable, safe launcher for RAVENNA ALSA + Merging Butler 1.1.93.
# Paths are always resolved relative to this repository.
# The local Butler configuration is generated from a versioned template.

USER_NAME="$(id -un)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_DIR="${SCRIPT_DIR}"

DRIVER_DIR="${REPO_DIR}/driver"
KO="${DRIVER_DIR}/MergingRavennaALSA.ko"

BUTLER_DIR="${REPO_DIR}/Butler"
BUTLER_ORIGINAL="${BUTLER_DIR}/Merging_RAVENNA_Daemon"
BUTLER_PATCHER="${BUTLER_DIR}/patch_curl_openssl4.py"
BUTLER="${BUTLER_DIR}/Merging_RAVENNA_Daemon.curl4-elf-test"
BUTLER_VERSION_FILE="${BUTLER_DIR}/VERSION"

BUTLER_CONFIG_TEMPLATE="${BUTLER_DIR}/merging_ravenna_daemon.conf.example"
BUTLER_CONFIG="${BUTLER_DIR}/merging_ravenna_daemon.conf"

MODULE="MergingRavennaALSA"
COMPAT_SYMBOL="butler_1_1_93_nl_rx_msg"
COMPAT_LOG_MARKER="Butler 1.1.93 compat: translated Add RTP stream"

say() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf '\nAVISO: %s\n' "$*" >&2
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

module_is_loaded() {
    lsmod | awk '{print $1}' | grep -qx "${MODULE}"
}

ko_has_butler_1193_compat() {
    local ko="$1"

    if command -v nm >/dev/null 2>&1; then
        if nm -g "${ko}" 2>/dev/null | awk '{print $3}' | grep -qx "${COMPAT_SYMBOL}"; then
            return 0
        fi
    fi

    grep -aFq "${COMPAT_LOG_MARKER}" "${ko}" 2>/dev/null
}

loaded_module_has_butler_1193_compat() {
    sudo grep -Eq \
        "[[:space:]]${COMPAT_SYMBOL}[[:space:]]+\\[${MODULE}\\]$" \
        /proc/kallsyms 2>/dev/null
}

interface_has_global_ipv4() {
    local iface="$1"
    ip -o -4 addr show dev "${iface}" up scope global 2>/dev/null | grep -q .
}

list_candidate_interfaces() {
    ip -o -4 addr show up scope global 2>/dev/null \
        | awk '{print $2}' \
        | sort -u
}

read_config_value() {
    local key="$1"

    if [[ -f "${BUTLER_CONFIG}" ]]; then
        awk -F= -v key="${key}" '$1 == key {print substr($0, index($0, "=") + 1); exit}' \
            "${BUTLER_CONFIG}" | tr -d '\r'
    fi
}

read_config_interface() {
    read_config_value "interface_name" | tr -d '[:space:]'
}

default_device_name() {
    local host
    host="$(hostname -s 2>/dev/null || hostname)"
    host="$(printf '%s' "${host}" | sed 's/[^A-Za-z0-9_]/_/g')"
    printf 'RAVENNA_%s\n' "${host}"
}

choose_ravenna_interface() {
    local configured=""
    local requested="${RAVENNA_INTERFACE:-}"
    local -a candidates=()
    local choice=""
    local i

    if [[ -n "${requested}" ]]; then
        interface_has_global_ipv4 "${requested}" || \
            die "RAVENNA_INTERFACE='${requested}' no existe, no está UP o no tiene IPv4 global."
        printf '%s\n' "${requested}"
        return 0
    fi

    configured="$(read_config_interface || true)"
    if [[ -n "${configured}" ]] && interface_has_global_ipv4 "${configured}"; then
        printf '%s\n' "${configured}"
        return 0
    fi

    mapfile -t candidates < <(list_candidate_interfaces)

    ((${#candidates[@]} > 0)) || \
        die "No encuentro interfaces UP con dirección IPv4 global."

    if ((${#candidates[@]} == 1)); then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi

    [[ -t 0 ]] || {
        printf >&2 '\nHay varias interfaces candidatas:\n'
        for i in "${!candidates[@]}"; do
            printf >&2 '  %d) %s  %s\n' \
                "$((i + 1))" \
                "${candidates[$i]}" \
                "$(ip -o -4 addr show dev "${candidates[$i]}" scope global | awk '{print $4}' | paste -sd, -)"
        done
        die "Ejecución no interactiva con varias NIC. Define RAVENNA_INTERFACE=<interfaz>."
    }

    printf >&2 '\nSelecciona la interfaz dedicada a RAVENNA/AES67:\n'
    for i in "${!candidates[@]}"; do
        printf >&2 '  %d) %-16s %s\n' \
            "$((i + 1))" \
            "${candidates[$i]}" \
            "$(ip -o -4 addr show dev "${candidates[$i]}" scope global | awk '{print $4}' | paste -sd, -)"
    done

    while true; do
        printf >&2 'Número de interfaz: '
        IFS= read -r choice

        if [[ "${choice}" =~ ^[0-9]+$ ]] &&
           ((choice >= 1 && choice <= ${#candidates[@]})); then
            printf '%s\n' "${candidates[$((choice - 1))]}"
            return 0
        fi

        printf >&2 'Selección no válida.\n'
    done
}

set_config_value() {
    local key="$1"
    local value="$2"
    local tmp

    tmp="$(mktemp)"
    awk -F= -v key="${key}" -v value="${value}" '
        BEGIN { found = 0 }
        $1 == key {
            print key "=" value
            found = 1
            next
        }
        { print }
        END {
            if (!found)
                print key "=" value
        }
    ' "${BUTLER_CONFIG}" > "${tmp}"

    cat "${tmp}" > "${BUTLER_CONFIG}"
    rm -f "${tmp}"
}

prepare_butler_config() {
    local iface="$1"
    local device_name=""

    [[ -f "${BUTLER_CONFIG_TEMPLATE}" ]] || \
        die "Falta la plantilla versionada: ${BUTLER_CONFIG_TEMPLATE}"

    if [[ ! -f "${BUTLER_CONFIG}" ]]; then
        cp "${BUTLER_CONFIG_TEMPLATE}" "${BUTLER_CONFIG}"
        echo "Configuración local creada desde:"
        echo "  ${BUTLER_CONFIG_TEMPLATE}"
    fi

    # Enforce the validated baseline while keeping the file host-local.
    set_config_value "interface_name" "${iface}"

    device_name="$(read_config_value "device_name" || true)"
    if [[ -z "${device_name}" || "${device_name}" == "CHANGE_ME" ]]; then
        device_name="$(default_device_name)"
        set_config_value "device_name" "${device_name}"
    fi

    set_config_value "web_app_port" "9090"
    set_config_value "web_app_path" "${BUTLER_DIR}/webapp/advanced"
    set_config_value "tic_frame_size_at_1fs" "48"
    set_config_value "config_pathname" "/var/alsa-aes67-driver/butler.config"
    set_config_value "default_sample_rate" "48000"

    echo "Configuración Butler local:"
    grep -E \
        '^(interface_name|device_name|web_app_port|web_app_path|tic_frame_size_at_1fs|config_pathname|default_sample_rate)=' \
        "${BUTLER_CONFIG}" || true
}

if [[ "${EUID}" -eq 0 ]]; then
    die "Ejecuta este script como usuario normal, SIN sudo. El script usará sudo cuando sea necesario."
fi

say "Repositorio: ${REPO_DIR}"
say "Usuario actual: ${USER_NAME}"

# ---------------------------------------------------------------------------
# 1. Select/prepare host-local Butler configuration
# ---------------------------------------------------------------------------
say "Preparando configuración local de Butler..."
RAVENNA_IFACE="$(choose_ravenna_interface)"
echo "Interfaz RAVENNA seleccionada: ${RAVENNA_IFACE}"
prepare_butler_config "${RAVENNA_IFACE}"

# ---------------------------------------------------------------------------
# 2. ALSA permissions
# ---------------------------------------------------------------------------
[[ -d /dev/snd ]] || die "No existe /dev/snd."

say "Comprobando permisos del usuario actual sobre ALSA (/dev/snd)..."

if ! id -nG "${USER_NAME}" | tr ' ' '\n' | grep -qx audio; then
    if getent group audio | awk -F: '{print "," $4 ","}' | grep -q ",${USER_NAME},"; then
        echo "El usuario ${USER_NAME} ya figura en el grupo 'audio', pero esta sesión aún no lo tiene activo."
    else
        echo "El usuario ${USER_NAME} no pertenece al grupo 'audio'. Añadiéndolo..."
        sudo usermod -aG audio "${USER_NAME}"
        echo "Usuario añadido correctamente al grupo 'audio'."
    fi

    cat <<EOF_REBOOT

============================================================
REINICIO DE SESIÓN/REBOOT NECESARIO
============================================================

Reinicia el equipo (o cierra completamente la sesión gráfica):

    sudo reboot

Después vuelve a ejecutar:

    ${REPO_DIR}/ravenna_check_and_run.sh

============================================================
EOF_REBOOT
    exit 0
fi

echo "OK: el grupo 'audio' está activo para ${USER_NAME}."

if command -v aplay >/dev/null 2>&1; then
    if ! aplay -l >/dev/null 2>&1; then
        ls -la /dev/snd || true
        die "'aplay -l' no puede acceder correctamente a ALSA sin sudo."
    fi
    echo "OK: 'aplay -l' funciona sin sudo."
else
    warn "No encuentro 'aplay'; continúo con las demás comprobaciones."
fi

# ---------------------------------------------------------------------------
# 3. Verify the driver built in THIS repository
# ---------------------------------------------------------------------------
say "Verificando el módulo RAVENNA de este repositorio..."

if [[ ! -f "${KO}" ]]; then
    cat >&2 <<EOF_BUILD

ERROR: no existe:

    ${KO}

Construye el driver compatible con Butler 1.1.93 desde este mismo clon:

    cd "${DRIVER_DIR}"
    make clean
    make -j"\$(nproc)" BUTLER_1193_COMPAT=1

Después vuelve a ejecutar:

    "${REPO_DIR}/ravenna_check_and_run.sh"

EOF_BUILD
    exit 1
fi

if command -v modinfo >/dev/null 2>&1; then
    VERMAGIC="$(modinfo -F vermagic "${KO}" 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "${VERMAGIC}" && "${VERMAGIC}" != "$(uname -r)" ]]; then
        die "El .ko fue compilado para kernel '${VERMAGIC}', pero el kernel activo es '$(uname -r)'. Recompila el driver en esta máquina."
    fi
fi

if ! ko_has_butler_1193_compat "${KO}"; then
    die "El .ko NO contiene el shim Butler 1.1.93 (${COMPAT_SYMBOL}). Recompila con BUTLER_1193_COMPAT=1."
fi

echo "OK: ${KO} contiene compatibilidad Butler 1.1.93."
echo "SHA256: $(sha256sum "${KO}" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# 4. Check/load kernel module
# ---------------------------------------------------------------------------
say "Comprobando módulo ${MODULE} en ejecución..."
sudo -v

if module_is_loaded; then
    echo "${MODULE} ya está cargado. Verificando el shim Butler 1.1.93..."

    if loaded_module_has_butler_1193_compat; then
        echo "OK: el módulo cargado contiene ${COMPAT_SYMBOL}."
    else
        cat >&2 <<EOF_WRONG_MODULE

ERROR: hay un ${MODULE} cargado, pero no puedo verificar que contenga
el shim Butler 1.1.93.

No arrancaré Butler con un módulo potencialmente incompatible.

Para sustituirlo de forma controlada:

    sudo pkill -f Merging_RAVENNA_Daemon 2>/dev/null || true
    sudo fuser -v /dev/snd/* 2>/dev/null || true
    sudo rmmod ${MODULE}

Después vuelve a ejecutar este script; cargará:

    ${KO}

EOF_WRONG_MODULE
        exit 1
    fi
else
    echo "Cargando el módulo construido en este repositorio:"
    echo "  ${KO}"
    sudo insmod "${KO}"

    module_is_loaded || die "insmod terminó, pero ${MODULE} no aparece en lsmod."
    loaded_module_has_butler_1193_compat || \
        die "El módulo recién cargado no expone ${COMPAT_SYMBOL}. No arrancaré Butler."

    echo "OK: módulo cargado y shim Butler 1.1.93 verificado."
fi

# ---------------------------------------------------------------------------
# 5. Verify ALSA/RAVENNA
# ---------------------------------------------------------------------------
say "Comprobando tarjeta RAVENNA..."

if grep -qi 'RAVENNA' /proc/asound/cards; then
    grep -A1 -i 'RAVENNA' /proc/asound/cards || true
else
    die "El módulo está cargado, pero RAVENNA no aparece en /proc/asound/cards."
fi

# ---------------------------------------------------------------------------
# 6. Verify Butler 1.1.93 and create CURL_OPENSSL_4 copy if needed
# ---------------------------------------------------------------------------
say "Comprobando Butler 1.1.93..."

[[ -f "${BUTLER_ORIGINAL}" ]] || die "No encuentro el Butler original: ${BUTLER_ORIGINAL}"
[[ -r "${BUTLER_VERSION_FILE}" ]] || die "No puedo leer: ${BUTLER_VERSION_FILE}"

grep -Fq '1.1 (build 93)' "${BUTLER_VERSION_FILE}" || \
    die "${BUTLER_VERSION_FILE} no identifica Butler 1.1 build 93."

echo "OK: VERSION identifica Butler 1.1 build 93."

if [[ ! -x "${BUTLER}" ]]; then
    echo "No existe todavía la copia Butler adaptada a CURL_OPENSSL_4."
    echo "Generándola sin modificar el binario original..."

    [[ -f "${BUTLER_PATCHER}" ]] || die "No encuentro el parcheador: ${BUTLER_PATCHER}"
    command -v python3 >/dev/null 2>&1 || die "Se necesita python3 para ejecutar ${BUTLER_PATCHER}."

    python3 "${BUTLER_PATCHER}" "${BUTLER_ORIGINAL}" "${BUTLER}"
    chmod +x "${BUTLER}"
fi

[[ -x "${BUTLER}" ]] || die "El Butler adaptado no es ejecutable: ${BUTLER}"

echo "Butler: ${BUTLER}"
echo "SHA256: $(sha256sum "${BUTLER}" | awk '{print $1}')"

if pgrep -f '[M]erging_RAVENNA_Daemon' >/dev/null 2>&1; then
    echo "OK: Merging_RAVENNA_Daemon ya está ejecutándose; no crearé otra instancia."
    pgrep -af '[M]erging_RAVENNA_Daemon' || true
    exit 0
fi

# ---------------------------------------------------------------------------
# 7. Start Butler
# ---------------------------------------------------------------------------
echo
echo "============================================================"
echo "PRE-FLIGHT CORRECTO"
echo "============================================================"
echo "Repositorio portable:    OK"
echo "Interfaz RAVENNA:         ${RAVENNA_IFACE}"
echo "Configuración local:      ${BUTLER_CONFIG}"
echo "Usuario ALSA:             OK"
echo "Driver del repositorio:   OK"
echo "Shim Butler 1.1.93:       OK"
echo "Tarjeta RAVENNA:          OK"
echo "Butler 1.1 build 93:      OK"
echo "CURL_OPENSSL_4:           OK"
echo "============================================================"
echo
echo "Arrancando Butler:"
echo "  cd ${BUTLER_DIR}"
echo "  sudo ./${BUTLER##*/}"
echo
echo "En dmesg, al crear streams RTP, debe aparecer:"
echo "  ${COMPAT_LOG_MARKER} 402 -> 403 bytes (...)"
echo

cd "${BUTLER_DIR}"
exec sudo "./${BUTLER##*/}"

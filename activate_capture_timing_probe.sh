#!/usr/bin/env bash
# Reload only the locally built RAVENNA module containing the read-only
# capture_timing_snapshot probe. Butler is deliberately not restarted here.
set -Eeuo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && ${1:-} != "--system-tai" ) ]]; then
    echo "Uso: sudo $0 [--system-tai]" >&2
    exit 2
fi

module_args=()
if [[ ${1:-} == "--system-tai" ]]; then
    module_args+=(use_system_tai_timeline=1)
fi

if [[ ${EUID} -ne 0 ]]; then
    echo "Ejecuta: sudo $0" >&2
    exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ko="${script_dir}/driver/MergingRavennaALSA.ko"
module="MergingRavennaALSA"
parameter="/sys/module/${module}/parameters/capture_timing_snapshot"

[[ -r "${ko}" ]] || { echo "No existe ${ko}" >&2; exit 1; }
[[ -n "$(modinfo -F vermagic "${ko}" 2>/dev/null)" ]] || {
    echo "${ko} no es un módulo válido" >&2
    exit 1
}
[[ "$(modinfo -F vermagic "${ko}" | awk '{print $1}')" == "$(uname -r)" ]] || {
    echo "El módulo no corresponde al kernel activo" >&2
    exit 1
}

if pgrep -f '[M]erging_RAVENNA_Daemon' >/dev/null; then
    echo "Deteniendo Butler para liberar el canal netlink…"
    pkill -TERM -f '[M]erging_RAVENNA_Daemon'
    for _ in {1..50}; do
        pgrep -f '[M]erging_RAVENNA_Daemon' >/dev/null || break
        sleep 0.1
    done
fi

if pgrep -f '[A]udioPluginHost' >/dev/null; then
    echo "AudioPluginHost sigue abierto; ciérralo antes de recargar el módulo." >&2
    exit 1
fi

if grep -q "^${module} " /proc/modules; then
    echo "Descargando ${module}…"
    rmmod "${module}"
fi

echo "Cargando la sonda de captura…"
insmod "${ko}" "${module_args[@]}"

[[ -r "${parameter}" ]] || {
    echo "El módulo cargó, pero no expone ${parameter}" >&2
    exit 1
}

grep -qi RAVENNA /proc/asound/cards || {
    echo "El módulo no ha creado la tarjeta RAVENNA" >&2
    exit 1
}

echo "OK: módulo instrumentado cargado. La sonda aún no será válida hasta que"
echo "Butler, la sesión AES67 y una captura ALSA estén en marcha."
if [[ ${#module_args[@]} -ne 0 ]]; then
    echo "Modo experimental activo: SAC se deriva de CLOCK_TAI; no hay filtrado de TL-TR."
fi
echo "Consulta: cat ${parameter}"

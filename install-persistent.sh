#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DRIVER_KO="$SCRIPT_DIR/driver/MergingRavennaALSA.ko"
BUTLER_DIR="$SCRIPT_DIR/Butler"
BUTLER_ORIGINAL="$BUTLER_DIR/Merging_RAVENNA_Daemon"
BUTLER_PATCHER="$BUTLER_DIR/patch_curl_openssl4.py"
BUTLER_VERSION="$BUTLER_DIR/VERSION"
WEBAPP_SOURCE="$BUTLER_DIR/webapp"
UNIT_SOURCE="$SCRIPT_DIR/systemd/merging-ravenna-butler.service"
UNINSTALL_SOURCE="$SCRIPT_DIR/uninstall-persistent.sh"

KERNEL_RELEASE="$(uname -r)"
MODULE_TARGET="/lib/modules/$KERNEL_RELEASE/updates/merging-ravenna/MergingRavennaALSA.ko"
MODULES_LOAD=/etc/modules-load.d/merging-ravenna.conf
UNIT=/etc/systemd/system/merging-ravenna-butler.service
CONFIG_DIR=/etc/merging-ravenna
CONFIG="$CONFIG_DIR/merging_ravenna_daemon.conf"
RUNTIME_ROOT=/opt/merging-ravenna
RUNTIME_BUTLER="$RUNTIME_ROOT/Butler"
RUNTIME_DAEMON="$RUNTIME_BUTLER/Merging_RAVENNA_Daemon.curl4"
STATE_DIR=/var/lib/merging-ravenna-install
UNINSTALL=/usr/local/sbin/uninstall-merging-ravenna

IFACE=""
START_NOW=0

usage() {
  cat <<EOF
Uso:
  sudo $0 --iface IFACE [--now]

Requiere que driver/MergingRavennaALSA.ko haya sido compilado para el kernel
activo con BUTLER_1193_COMPAT=1.
EOF
}

while (($#)); do
  case "$1" in
    --iface) IFACE="${2:-}"; shift 2 ;;
    --now) START_NOW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: argumento desconocido: $1" >&2; usage; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "ejecutar con sudo/root."
[[ "$IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "falta --iface o no es válida."
[[ -d "/sys/class/net/$IFACE" ]] || die "no existe la interfaz $IFACE."

for source_file in "$DRIVER_KO" "$BUTLER_ORIGINAL" "$BUTLER_PATCHER" \
  "$BUTLER_VERSION" "$UNIT_SOURCE" "$UNINSTALL_SOURCE"; do
  [[ -f "$source_file" ]] || die "falta $source_file."
done
[[ -d "$WEBAPP_SOURCE" ]] || die "falta $WEBAPP_SOURCE."
command -v python3 >/dev/null 2>&1 || die "se necesita python3."
command -v depmod >/dev/null 2>&1 || die "se necesita depmod."

PATCHED_BUTLER="$(mktemp)"
cleanup() {
  rm -f "$PATCHED_BUTLER"
}
trap cleanup EXIT
python3 "$BUTLER_PATCHER" "$BUTLER_ORIGINAL" "$PATCHED_BUTLER"

VERMAGIC="$(modinfo -F vermagic "$DRIVER_KO" 2>/dev/null | awk '{print $1}')"
[[ "$VERMAGIC" == "$KERNEL_RELEASE" ]] ||
  die "el módulo es para '${VERMAGIC:-desconocido}', no para '$KERNEL_RELEASE'."

if command -v nm >/dev/null 2>&1; then
  nm -g "$DRIVER_KO" 2>/dev/null | awk '{print $3}' |
    grep -qx butler_1_1_93_nl_rx_msg ||
    die "el módulo no contiene la compatibilidad Butler 1.1.93."
else
  grep -aFq 'Butler 1.1.93 compat: translated Add RTP stream' "$DRIVER_KO" ||
    die "no se pudo verificar la compatibilidad Butler 1.1.93."
fi

backup_once() {
  local path="$1" key="$2"
  [[ -e "$STATE_DIR/$key.state" ]] && return 0
  if [[ -e "$path" || -L "$path" ]]; then
    printf 'present\n' >"$STATE_DIR/$key.state"
    cp -a "$path" "$STATE_DIR/$key.backup"
  else
    printf 'absent\n' >"$STATE_DIR/$key.state"
  fi
}

set_config_value() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -F= -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $1 == key { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$CONFIG" >"$tmp"
  install -m 0644 "$tmp" "$CONFIG"
  rm -f "$tmp"
}

if [[ -e "$RUNTIME_ROOT" && ! -e "$STATE_DIR/runtime.owned" ]]; then
  die "$RUNTIME_ROOT ya existía y no pertenece a este instalador."
fi

install -d -m 0755 "$STATE_DIR" "$(dirname -- "$MODULE_TARGET")" \
  /etc/modules-load.d /etc/systemd/system "$CONFIG_DIR" \
  "$RUNTIME_BUTLER/webapp/advanced" /var/alsa-aes67-driver
touch "$STATE_DIR/runtime.owned"

backup_once "$MODULE_TARGET" module
backup_once "$MODULES_LOAD" modules_load
backup_once "$UNIT" unit
backup_once "$CONFIG" config
backup_once "$UNINSTALL" uninstall

install -m 0644 "$DRIVER_KO" "$MODULE_TARGET"
printf 'MergingRavennaALSA\n' >"$MODULES_LOAD"
chmod 0644 "$MODULES_LOAD"

cp -a "$WEBAPP_SOURCE/." "$RUNTIME_BUTLER/webapp/"
install -m 0644 "$BUTLER_VERSION" "$RUNTIME_BUTLER/VERSION"
[[ -f "$BUTLER_DIR/LICENSE.md" ]] &&
  install -m 0644 "$BUTLER_DIR/LICENSE.md" "$RUNTIME_BUTLER/LICENSE.md"
install -m 0755 "$PATCHED_BUTLER" "$RUNTIME_DAEMON"

if [[ ! -f "$CONFIG" ]]; then
  install -m 0644 "$BUTLER_DIR/merging_ravenna_daemon.conf.example" "$CONFIG"
fi
set_config_value interface_name "$IFACE"
DEVICE_NAME="RAVENNA_$(hostname -s | sed 's/[^A-Za-z0-9_]/_/g')"
CURRENT_DEVICE="$(awk -F= '$1=="device_name"{print substr($0,index($0,"=")+1);exit}' "$CONFIG")"
if [[ -z "$CURRENT_DEVICE" || "$CURRENT_DEVICE" == CHANGE_ME ]]; then
  set_config_value device_name "$DEVICE_NAME"
fi
set_config_value web_app_port 9090
set_config_value web_app_path "$RUNTIME_BUTLER/webapp/advanced"
set_config_value tic_frame_size_at_1fs 48
set_config_value config_pathname /var/alsa-aes67-driver/butler.config
set_config_value default_sample_rate 48000
ln -sfn "$CONFIG" "$RUNTIME_BUTLER/merging_ravenna_daemon.conf"

install -m 0644 "$UNIT_SOURCE" "$UNIT"
install -m 0755 "$UNINSTALL_SOURCE" "$UNINSTALL"
depmod -a "$KERNEL_RELEASE"
SELECTED_MODULE="$(modinfo -n MergingRavennaALSA 2>/dev/null || true)"
[[ -n "$SELECTED_MODULE" &&
   "$(readlink -f "$SELECTED_MODULE")" == "$(readlink -f "$MODULE_TARGET")" ]] ||
  die "depmod no selecciona el módulo instalado: ${SELECTED_MODULE:-no encontrado}."
systemctl daemon-reload
systemctl enable merging-ravenna-butler.service

echo "Módulo instalado: $MODULE_TARGET"
echo "Butler instalado: $RUNTIME_DAEMON"
echo "Configuración:    $CONFIG"
echo "Servicio habilitado para el siguiente arranque."

if ((START_NOW)); then
  if pgrep -f '[M]erging_RAVENNA_Daemon' >/dev/null 2>&1; then
    die "ya existe un Butler manual. Deténlo antes de usar --now."
  fi
  systemctl start merging-ravenna-butler.service
  systemctl --no-pager --full status merging-ravenna-butler.service
else
  echo "Para activarlo ahora: sudo systemctl start merging-ravenna-butler.service"
fi

if lsmod | awk '{print $1}' | grep -qx MergingRavennaALSA; then
  LOADED_SRCVERSION="$(cat /sys/module/MergingRavennaALSA/srcversion 2>/dev/null || true)"
  INSTALLED_SRCVERSION="$(modinfo -F srcversion "$MODULE_TARGET" 2>/dev/null || true)"
  if [[ "$LOADED_SRCVERSION" != "$INSTALLED_SRCVERSION" ]]; then
    echo "AVISO: el módulo cargado no coincide con el instalado; se activará tras reiniciar."
  fi
fi

echo "Rollback: sudo $UNINSTALL"

#!/usr/bin/env bash
set -Eeuo pipefail

KERNEL_RELEASE="$(uname -r)"
MODULE_TARGET="/lib/modules/$KERNEL_RELEASE/updates/merging-ravenna/MergingRavennaALSA.ko"
MODULES_LOAD=/etc/modules-load.d/merging-ravenna.conf
UNIT=/etc/systemd/system/merging-ravenna-butler.service
CONFIG=/etc/merging-ravenna/merging_ravenna_daemon.conf
RUNTIME_ROOT=/opt/merging-ravenna
STATE_DIR=/var/lib/merging-ravenna-install

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "ERROR: ejecutar con sudo/root." >&2
  exit 1
}

systemctl disable --now merging-ravenna-butler.service 2>/dev/null || true

restore_one() {
  local path="$1" key="$2" state=""
  [[ -r "$STATE_DIR/$key.state" ]] || return 0
  state="$(cat "$STATE_DIR/$key.state")"
  rm -f "$path"
  if [[ "$state" == present ]]; then
    install -d -m 0755 "$(dirname -- "$path")"
    cp -a "$STATE_DIR/$key.backup" "$path"
  fi
  rm -f "$STATE_DIR/$key.state" "$STATE_DIR/$key.backup"
}

restore_one "$MODULE_TARGET" module
restore_one "$MODULES_LOAD" modules_load
restore_one "$UNIT" unit
restore_one "$CONFIG" config

if [[ -e "$STATE_DIR/runtime.owned" && "$RUNTIME_ROOT" == /opt/merging-ravenna ]]; then
  rm -rf -- "$RUNTIME_ROOT"
  rm -f "$STATE_DIR/runtime.owned"
fi

depmod -a "$KERNEL_RELEASE"
systemctl daemon-reload
rmdir /etc/merging-ravenna 2>/dev/null || true
rmdir "$STATE_DIR" 2>/dev/null || true

echo "Persistencia RAVENNA retirada y ficheros anteriores restaurados."
echo "El módulo actualmente cargado no se descarga; el cambio será efectivo al reiniciar."

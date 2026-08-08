# Ubuntu 26.04 / Linux 7.x + Merging Butler 1.1 build 93

This note documents the compatibility work validated on Ubuntu 26.04 LTS with
Linux `7.0.0-29-generic`, x86-64, using the `aes67-daemon` branch.

## What works

The v2.1 driver builds and loads on Linux 7.0.0-29, exposes the RAVENNA ALSA
playback/capture device, receives PTP on the selected Ethernet interface, locks
to the Grandmaster, and can be controlled by Merging Butler 1.1 build 93 after
two compatibility adaptations described below.

Validated observations included:

- `MergingRavennaALSA.ko` builds successfully against 7.0.0-29 headers.
- ALSA exposes RAVENNA playback and capture devices.
- Butler initialises successfully and serves its web UI on TCP 9090.
- PTP Sync, Follow_Up and Announce are received on domain 0.
- The kernel PTP state transitions `UNLOCKED -> LOCKING -> LOCKED`.
- Butler's PTP page displays status once the legacy PTP Netlink ABI shim is
  enabled.

## 1. Build the driver for Butler 1.1.93

Driver v2.0 extended `TPTPStatus` for dual-NIC/ST 2022-7 operation:

- 1.1.93 layout: 16 bytes (`lock`, one `GMID`, one legacy jitter value)
- v2.0+ layout: 36 bytes (two GMIDs, per-interface state, network/clock jitter)

The proprietary Butler 1.1 build 93 binary explicitly rejects any PTP status
reply whose payload size is not 16 bytes.  The PTP engine itself is not the
problem; only the user/kernel ABI at `MT_ALSA_Msg_GetPTPStatus` differs.

Build the module with the compatibility adapter enabled:

```bash
cd driver
make clean
make -j"$(nproc)" BUTLER_1193_COMPAT=1
```

The adapter changes only Netlink replies originating from `manager.c` for
`MT_ALSA_Msg_GetPTPStatus`.  Internally, the v2.1 `TPTPStatus`, dual-NIC support,
PTP code and ST 2022-7 structures remain unchanged.

The legacy reply is mapped as follows:

| Butler 1.1.93 field | v2.1 source |
| --- | --- |
| `nPTPLockStatus` | modern `nPTPLockStatus` |
| `ui64GMID` | modern `ui64GMID[0]` |
| `i32Jitter` | `0`, matching the original 1.1.93 implementation |

A normal build without `BUTLER_1193_COMPAT=1` retains the upstream v2.1
36-byte ABI and remains suitable for software that understands the newer
structure.

## 2. Patch the old Butler libcurl symbol version

The distributed Butler binary requires `CURL_OPENSSL_3`, while current Ubuntu
libcurl exports the required `curl_easy_*` functions under `CURL_OPENSSL_4`.
The binary imports only:

- `curl_easy_init`
- `curl_easy_setopt`
- `curl_easy_perform`
- `curl_easy_getinfo`
- `curl_easy_cleanup`

Do not replace system libraries and do not install an obsolete libcurl globally.
Use the supplied patcher to create a separate executable:

```bash
cd Butler
python3 patch_curl_openssl4.py \
  Merging_RAVENNA_Daemon \
  Merging_RAVENNA_Daemon.curl4

ldd ./Merging_RAVENNA_Daemon.curl4
```

The script updates both the text version name and its `Elf64_Vernaux.vna_hash`
in `.gnu.version_r`.  Replacing the string alone is not sufficient: the dynamic
loader also verifies the stored ELF hash.

The original `Merging_RAVENNA_Daemon` is never modified in place.

## Example Butler configuration

For an AES67 interface named `eno1` at 48 kHz:

```ini
interface_name=eno1
device_name=RAVENNA_xubuntu_HP_Pro
web_app_port=9090
web_app_path=/home/xubuntu/ravenna-alsa-lkm/Butler/webapp/advanced
tic_frame_size_at_1fs=48
config_pathname=/var/alsa-aes67-driver/butler.config
default_sample_rate=48000
```

Prepare persistent storage and start in foreground for the first test:

```bash
sudo mkdir -p /var/alsa-aes67-driver
sudo insmod driver/MergingRavennaALSA.ko
cd Butler
sudo ./Merging_RAVENNA_Daemon.curl4
```

The web UI is then normally reachable at:

```text
http://<RAVENNA-interface-IP>:9090/
```

## PTP status compatibility background

The original driver release associated with Butler 1.1.93 used:

```c
typedef struct {
    EPTPLockStatus nPTPLockStatus;
    uint64_t ui64GMID;
    int32_t i32Jitter;
} TPTPStatus;
```

Later ST 2022-7 support changed it to the dual-interface representation.  Butler
1.1.93 contains a hard-coded comparison against `0x10` (16 bytes) before it
copies the returned structure, which is why an unmodified v2.1 driver produces:

```text
mdc_get_PTPStatus struct size missmatch. A Driver update is requested.
```

That message is misleading in this case: the driver is newer than Butler, not
older.  The compatibility adapter intentionally restores only the legacy
Netlink representation instead of downgrading the kernel driver or changing the
PTP algorithm.

## Notes

- The compatibility layer has been validated with a single active RAVENNA NIC.
- Legacy Butler cannot represent the complete v2.1 dual-NIC PTP status in its
  16-byte structure.  It receives the active/first GMID compatibility view.
- Keep the original Butler executable for rollback and verification.
- Secure Boot may require signing the locally built kernel module before it can
  be loaded.

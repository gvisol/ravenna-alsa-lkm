# ALSA RAVENNA/AES67 Driver

> This repository is an improved fork of Merging Technologies' original [RAVENNA ALSA driver](https://bitbucket.org/MergingTechnologies/ravenna-alsa-lkm/src/).

## `aes67-daemon` branch status

This branch has been updated and functionally validated on **Ubuntu 26.04 LTS**, **Linux `7.0.0-29-generic`**, **x86-64**, using the v2.1 RAVENNA ALSA driver together with **Merging Butler 1.1 build 93**.

The compatibility work is intentionally opt-in. A normal driver build keeps the current v2.1 ABI and ST 2022-7 data structures unchanged. Build with `BUTLER_1193_COMPAT=1` only when the proprietary legacy Butler 1.1.93 binary must control the current driver.

Detailed validation notes are available in [`docs/ubuntu-26.04-kernel7-butler-1.1.93.md`](docs/ubuntu-26.04-kernel7-butler-1.1.93.md).

### Validated functionality

The following path has been exercised successfully on the test system:

```text
Butler 1.1.93
    -> Netlink compatibility adapter
    -> RAVENNA ALSA driver v2.1
    -> PTP lock
    -> ALSA playback
    -> RTP/L24 multicast TX
    -> physical Ethernet ingress
    -> RTP/L24 RX
    -> ALSA capture
```

Validated observations include:

- `MergingRavennaALSA.ko` builds and loads against Linux `7.0.0-29` headers.
- ALSA exposes RAVENNA playback and capture devices.
- Butler 1.1.93 starts on Ubuntu 26.04 after patching its legacy libcurl symbol-version dependency.
- The Butler web UI is served normally on the configured interface and TCP port.
- PTP Sync, Follow_Up and Announce are received on domain 0.
- The driver transitions from `UNLOCKED` to `LOCKING` to `LOCKED` against the tested Grandmaster.
- Butler's legacy 16-byte PTP status ABI is translated from the v2.1 36-byte internal representation.
- Butler Session Sources and Session Sinks both create RTP streams through the legacy 402-byte to v2.1 403-byte Add-RTP adapter.
- Two-channel L24 RTP transmission at 48 kHz and 48 samples/packet has been observed on the network.
- Physical multicast ingress has been validated through the driver to two-channel `S32_LE` ALSA capture.
- ALSA capture with `period_size=48` is valid and has been tested successfully with the 48-sample RAVENNA/PTP TIC.
- ALSA capture now derives its jitter-buffer read position from an atomic SAC snapshot on every PTP TIC. This removes restart-dependent one-TIC latency states without filtering or altering received audio.
- Legacy ALSA diagnostics were clarified so byte ranges and independent ALSA/RAVENNA buffer geometries are not presented as errors.
- The missing Butler `network-started.png` web asset has been restored, fixing the broken Session Sink `Started` state icon.

This establishes **functional compatibility for the tested configuration**. It is **not** a complete AES67 or RAVENNA conformance certification.

### Repeatable capture latency across application restarts

Previously, `pcm_prepare()` initialized the input jitter-buffer position from
the current absolute sample counter (SAC), after which the position advanced
independently. ALSA prepare and the next PTP TIC are asynchronous, and the PTP
servo may re-align SAC, so the captured sample block could acquire a stable
restart-dependent displacement of one TIC (1 ms at the validated 48-sample /
48 kHz geometry).

The capture interrupt now obtains SAC through the driver's existing atomic
time snapshot and derives the jitter-buffer read position for every TIC. The
callback also reports success when it returns a valid position. This is an
index/timeline correction only: it performs no smoothing, outlier rejection,
sample insertion/deletion, or latency compensation.

Validation with ten independent 20-second OnTimeCM starts produced per-run
mean TL-TR values from `12.430` to `12.525 ms`, a cross-run span of `0.095 ms`,
with no offset change inside any run. Signal quality remained approximately
`33.2 dB`.

### Butler 1.1.93 compatibility changes

#### PTP status ABI

Driver v2.0 extended `TPTPStatus` for dual-interface/ST 2022-7 operation. Butler 1.1 build 93 predates that change and rejects a PTP-status reply whose payload is not exactly 16 bytes.

| ABI | `TPTPStatus` size |
| --- | ---: |
| Butler 1.1.93 | 16 bytes |
| driver v2.0+/v2.1 | 36 bytes |

With `BUTLER_1193_COMPAT=1`, only the legacy Butler-facing Netlink reply is translated. The driver's internal v2.1 structure and ST 2022-7 implementation remain unchanged.

The legacy fields are mapped as follows:

| Butler 1.1.93 field | v2.1 source |
| --- | --- |
| PTP lock state | current `nPTPLockStatus` |
| Grandmaster ID | `ui64GMID[0]` |
| Jitter | `i32ClockJitter` |

The value displayed by the old Butler UI as `Delta`/`Jitter` is the driver's **TIC scheduling clock-jitter statistic in microseconds**. It must not be interpreted as IEEE 1588 `offsetFromMaster`. The web UI has been corrected to show the `µs` unit explicitly.

#### RTP stream ABI

The ST 2022-7 update inserted `m_bIsPrimaryPort` into the packed `TRTP_stream_info` structure. This changed the Netlink payload size by one byte:

| ABI | `TRTP_stream_info` size |
| --- | ---: |
| Butler 1.1.93 / pre-ST-2022-7 | 402 bytes |
| driver v2.0+/v2.1 | 403 bytes |

Without translation, the current driver rejects Butler's Add-RTP request with:

```text
Add RTP stream invalid data size
```

The compatibility adapter accepts the exact legacy 402-byte representation, inserts `m_bIsPrimaryPort`, copies the routing array to its correct shifted offset, updates the embedded size and Netlink payload size, and then passes the translated 403-byte message to the normal v2.1 handler.

This path has been validated for both **Session Source** and **Session Sink** creation in the tested single-interface configuration. Butler 1.1.93 cannot express the complete modern dual-interface ST 2022-7 semantics, so this compatibility mode must not be interpreted as full legacy-Butler ST 2022-7 support.

### Validated RTP format

The TX/RX validation used:

```text
sample rate       48000 Hz
codec             L24
channels          2
samples/packet    48
packet period     1 ms
payload type      98
DSCP              34 (AF41)
TTL               15
multicast         239.1.0.252:5004
PTP domain        0
```

Packetisation observed on the wire:

```text
48 samples * 2 channels * 3 bytes = 288 bytes audio
12 bytes RTP header                =  12 bytes
                                      ---------
UDP payload                        = 300 bytes
```

Successive RTP packets incremented the sequence number by one and the RTP timestamp by 48 samples. With the Butler source enabled but no ALSA playback stream open, no RTP packets were transmitted. During active playback, approximately 1000 RTP packets/s were observed, as expected for 48 samples/packet at 48 kHz.

### Physical RX validation

A same-interface local TX-to-RX loop is not a valid receive-path test for this driver because transmitted packets leave through the network TX path and do not re-enter the driver's Netfilter `PRE_ROUTING` receive hook.

The successful receive test therefore used a second physical Ethernet interface to regenerate only the outer UDP/IP source while preserving the original RTP header and L24 payload. The packet then traversed the Ethernet switch and returned as real physical ingress on the RAVENNA RX interface.

The validated path was:

```text
ALSA playback
    -> RAVENNA Source
    -> physical TX
    -> RTP-preserving relay on second NIC
    -> Ethernet switch
    -> physical RX
    -> Butler Session Sink
    -> L24 depacketisation/routing
    -> ALSA S32_LE capture
```

The capture contained non-zero programme audio on both channels and a 1 kHz stimulus was recovered at approximately `1000.083 Hz` with the finite-window zero-crossing estimator used during validation.

### ALSA period and buffer geometry

At 48 kHz the driver accepts an ALSA capture period of 48 frames. The tested geometry was:

```text
sample rate       48000
channels          2
format            S32_LE
period_size       48
buffer_size       1536
periods           32
PTP frame size    48
```

This aligns the tested timing units:

```text
RTP packet         48 samples = 1 ms
RAVENNA/PTP TIC    48 samples = 1 ms
ALSA capture       48 samples = 1 ms
```

Two important legacy diagnostics were also corrected:

- the old `capture period size range: [96, 196608]` values are **bytes**, not frames, and are now labelled `period byte range`;
- the ALSA userspace buffer is independent of the complete internal RAVENNA ring buffer, so the former `nbPeriods (...) differs from expected (1024)` comparison was misleading and has been removed in favour of an explicit geometry diagnostic.

These diagnostic changes do not alter ALSA constraints, PTP/TIC sizing, RTP processing or buffer operation.

### Current validation limits

The current tests do not yet establish:

- long-duration stability;
- packet-loss recovery behaviour;
- operation under deliberately impaired network jitter;
- full redundant ST 2022-7 operation with Butler 1.1.93;
- exhaustive interoperability with independent third-party AES67/RAVENNA senders;
- formal AES67 or RAVENNA conformance.

## Portable deployment and validation milestones

The repository root includes `ravenna_check_and_run.sh`, a portable
pre-flight and launch helper for the validated Butler 1.1.93
compatibility configuration.

The launcher resolves the driver and Butler paths relative to the
repository itself. It therefore does not depend on the username, home
directory, clone directory, or the validation worktree used during
development.

Before launching Butler, the script:

- selects or validates the RAVENNA/AES67 network interface;
- creates the host-local Butler configuration from the versioned
  `Butler/merging_ravenna_daemon.conf.example` template when necessary;
- enforces the validated 48 kHz baseline with a 48-sample RAVENNA/PTP TIC;
- writes the absolute `web_app_path` corresponding to the current clone;
- verifies ALSA access for the current user;
- verifies that the kernel module built in this repository contains the
  Butler 1.1.93 compatibility shim;
- refuses to continue if an already loaded `MergingRavennaALSA` module
  cannot be verified as Butler-1.1.93 compatible;
- checks that the loaded module exposes the RAVENNA ALSA card;
- verifies Butler 1.1 build 93;
- generates the `CURL_OPENSSL_4`-compatible Butler copy from the original
  executable when the generated copy is absent;
- avoids starting a duplicate Butler process.

The driver is deliberately **not** compiled automatically by the launcher.
Build it explicitly for the active kernel before first use:

```bash
cd driver
make clean
make -j"$(nproc)" BUTLER_1193_COMPAT=1
cd ..
```

Then run:

```bash
./ravenna_check_and_run.sh
```

### Persistent module and Butler service

For a fixed production host, the repository also contains a reversible
systemd installer. Build the exact driver first and then install it together
with the patched Butler runtime:

```bash
cd driver
make clean
make -j"$(nproc)" BUTLER_1193_COMPAT=1
cd ..

sudo ./install-persistent.sh --iface eno1
```

This installs the module under
`/lib/modules/$(uname -r)/updates/merging-ravenna/`, runs `depmod`, adds a
`modules-load.d` entry, creates the CURL_OPENSSL_4 Butler copy under
`/opt/merging-ravenna`, writes the host configuration under
`/etc/merging-ravenna`, and enables `merging-ravenna-butler.service`.

If the manually launched Butler and all ALSA clients are already stopped, the
service can be activated immediately with `--now`. Otherwise, install without
`--now` and let the new module/service become active on the next reboot.

```bash
systemctl status merging-ravenna-butler.service
journalctl -u merging-ravenna-butler.service
```

The unit is ordered after `network-online.target` and, when installed, after
`ontime-ptp-sync.service`. This ordering does not couple the two PTP servos:
RAVENNA continues using its own PTP/SAC timeline, while linuxptp disciplines
the Linux clocks used by OnTimeCM.

Kernel modules are kernel-release specific. After installing a new kernel,
rebuild the driver against its headers and rerun `install-persistent.sh` before
booting that kernel into production.

Rollback is explicit and does not unload an in-use kernel module:

```bash
sudo ./uninstall-persistent.sh
sudo reboot
```

If the host has more than one active IPv4 interface and no valid local
Butler configuration exists yet, the launcher asks which interface is the
RAVENNA/AES67 interface instead of guessing.

For unattended use the interface can be selected explicitly:

```bash
RAVENNA_INTERFACE=eno1 ./ravenna_check_and_run.sh
```

Replace `eno1` with the media interface on that host.

### Versioned template versus host-local configuration

The portable layout separates repository state from machine-specific
runtime state:

```text
Butler/merging_ravenna_daemon.conf.example
    versioned template

Butler/merging_ravenna_daemon.conf
    host-local runtime configuration
    generated/updated by ravenna_check_and_run.sh
    ignored by Git
```

The versioned template deliberately uses a minimal `key=value` format
for compatibility with the legacy Butler parser:

```ini
interface_name=CHANGE_ME
device_name=CHANGE_ME
web_app_port=9090
tic_frame_size_at_1fs=48
config_pathname=/var/alsa-aes67-driver/butler.config
default_sample_rate=48000
```

At runtime the launcher replaces `interface_name`, generates a default
`device_name` from the host name when one has not already been configured,
adds the absolute `web_app_path`, and keeps the validated 48-sample /
48 kHz baseline. A user-supplied `device_name` is preserved.

Generated kernel build products, patched Butler binaries, local Butler
configuration, and local backup files are intentionally excluded from
version control.

### Validation tags

Two annotated tags distinguish the validated compatibility baseline from
the reproducible deployment package:

- `v2.1-butler-1.1.93-validated` — validated Butler 1.1.93/current-driver
  compatibility baseline before the portable deployment helper was added.
- `v2.1-butler-1.1.93-portable` — reproducible deployment state containing
  the portable launcher, host-local configuration layout, ignore rules,
  and deployment documentation.

After the portable tag is published, the exact deployment state can be
recreated on another machine with:

```bash
git clone \
  --branch v2.1-butler-1.1.93-portable \
  https://github.com/gvisol/ravenna-alsa-lkm.git

cd ravenna-alsa-lkm

cd driver
make clean
make -j"$(nproc)" BUTLER_1193_COMPAT=1
cd ..

./ravenna_check_and_run.sh
```

The manual procedure below remains useful for diagnostics, development,
and understanding each individual step.

## Build and run on Ubuntu 26.04 with Butler 1.1.93

### 1. Clone this branch

```bash
git clone -b aes67-daemon https://github.com/gvisol/ravenna-alsa-lkm.git
cd ravenna-alsa-lkm
```

### 2. Build the driver

For Butler 1.1.93 compatibility:

```bash
cd driver
make clean
make -j"$(nproc)" BUTLER_1193_COMPAT=1
```

For a normal v2.1 build without the legacy adapter:

```bash
make clean
make -j"$(nproc)"
```

Load the built module for testing:

```bash
sudo insmod MergingRavennaALSA.ko
```

Or install it persistently:

```bash
sudo cp MergingRavennaALSA.ko /lib/modules/$(uname -r)/kernel/drivers/
sudo depmod -a
```

### 3. Patch Butler's legacy libcurl symbol requirement

The distributed Butler 1.1.93 binary requires `CURL_OPENSSL_3`, while modern Ubuntu libcurl exports the required `curl_easy_*` API under `CURL_OPENSSL_4`.

Do **not** replace the system libcurl and do **not** modify the original Butler executable in place. The repository contains a reproducible ELF patcher that updates both the version string and the corresponding ELF `Vernaux` hash in a copy of the executable:

```bash
cd ../Butler
python3 patch_curl_openssl4.py \
    Merging_RAVENNA_Daemon \
    Merging_RAVENNA_Daemon.curl4-elf-test
```

The original binary is left unchanged. The generated
`Merging_RAVENNA_Daemon.curl4-elf-test` file is a local runtime artifact
and is ignored by Git. The portable launcher creates it automatically when
it is missing.

### 4. Configure Butler

For portable deployments, do **not** version a machine-specific
`Butler/merging_ravenna_daemon.conf`.

The repository contains the versioned template:

```text
Butler/merging_ravenna_daemon.conf.example
```

The recommended launcher, `ravenna_check_and_run.sh`, creates the local
`Butler/merging_ravenna_daemon.conf` from that template when it is absent.
The local file is ignored by Git.

When several active IPv4 interfaces are present, the launcher asks which
one is dedicated to RAVENNA/AES67. The selection can also be supplied
explicitly through `RAVENNA_INTERFACE`.

The launcher then sets the validated baseline using a deliberately
minimal `key=value` configuration:

```ini
interface_name=<host RAVENNA interface>
device_name=RAVENNA_<normalized-hostname>
web_app_port=9090
web_app_path=<current clone>/Butler/webapp/advanced
tic_frame_size_at_1fs=48
config_pathname=/var/alsa-aes67-driver/butler.config
default_sample_rate=48000
```

If a host-local `device_name` already exists, the launcher preserves it.

The important options are:

- `interface_name`: Ethernet interface used for RAVENNA/AES67;
- `web_app_port`: Butler web server TCP port, normally 9090;
- `web_app_path`: absolute path to `Butler/webapp/advanced` in the current clone;
- `tic_frame_size_at_1fs`: RAVENNA/PTP TIC size at 44.1/48 kHz; 48 samples is the validated AES67 value;
- `config_pathname`: persistent Butler stream/configuration state;
- `default_sample_rate`: initial audio sample rate, set to 48000 in the validated baseline.

Additional Butler options may be added to the host-local configuration as
required. Because that file is not tracked, machine-specific settings do
not contaminate the portable repository state.

### 5. Launch Butler

The recommended method is to return to the repository root and use the
portable launcher:

```bash
cd ..
./ravenna_check_and_run.sh
```

The launcher verifies the compatible driver, ALSA access, Butler version,
host-local configuration and libcurl compatibility before starting Butler.

For manual diagnostics, Butler can still be patched and launched directly.
Using the same generated filename as the portable launcher:

```bash
cd Butler
python3 patch_curl_openssl4.py \
    Merging_RAVENNA_Daemon \
    Merging_RAVENNA_Daemon.curl4-elf-test

chmod u+x Merging_RAVENNA_Daemon.curl4-elf-test
sudo ./Merging_RAVENNA_Daemon.curl4-elf-test
```

Butler requires the RAVENNA kernel module to be loaded first. The module
cannot be removed while Butler is using it.

The web UI is available on the configured media-interface address, for
example:

```text
http://172.30.0.252:9090/
```

The example address above is specific to the validated test host. On
another machine use the IPv4 address assigned to its selected
`interface_name`.

The web server may bind only to `interface_name`; `127.0.0.1:9090` is
therefore not necessarily reachable.

## License

Although the kernel part of this software is licensed under the [GNU GPL](https://www.gnu.org/licenses/gpl-3.0.en.html), the user-land Butler is distributed under separate terms depending on use:

**A. Integration into commercial products**  
Please contact Merging Technologies through their [general enquiries page](https://www.merging.com/company/general-inquiries).

**B. Personal use**  
See the Butler license in the original Merging Technologies repository.

## Architecture

The RAVENNA ALSA implementation is split into two parts:

1. the Linux kernel module, `MergingRavennaALSA.ko`;
2. the user-land Butler, `Merging_RAVENNA_Daemon`.

### Kernel module responsibilities

- register as an ALSA driver;
- generate and receive RTP audio packets;
- run the PTP-driven audio interrupt/TIC loop;
- communicate with Butler through Netlink.

### Butler responsibilities

- configure and control the kernel module;
- implement high-level RAVENNA/AES67 functions;
- mDNS discovery;
- SAP discovery;
- NMOS IS-04/05 discovery/registration/management where supported by the Butler build;
- arbitrate RAVENNA device sample rate;
- serve the web UI;
- expose CometD / HTTP REST APIs;
- provide remote volume control.

## ALSA features

- 1FS to 8FS support;
- PCM up to 384 kHz;
- native DSD 64/128/256 in playback only;
- interleaved and non-interleaved 16/24/32-bit integer formats as supported by the driver;
- up to 64 I/O in OEM builds;
- public build limited to 8 I/O if no Merging device is present;
- volume control.

Non-interleaved capture is not supported by the original public implementation.

## Network requirements

A multicast-capable 1 Gb/s Ethernet network is recommended. The switch should support multicast forwarding, IGMPv2 and IGMP snooping.

Relevant protocols/ports include:

- Butler web server: configured TCP port, normally 9090;
- mDNS: UDP 5353;
- AES67 discovery/SAP: UDP 9875 where used;
- PTP event/general: UDP 319 and 320;
- RTP audio: stream-specific UDP ports configured by Butler/SDP.

A PTP Grandmaster is required; this driver is not intended to act as the PTP master.

The public Butler uses Avahi when available. A Zeroconf/mDNS service should therefore be running on the host.

## Testing ALSA

List the detected ALSA devices first:

```bash
aplay -l
arecord -l
```

Basic playback at the validated 48 kHz / 48-frame geometry:

```bash
speaker-test \
    -D hw:RAVENNA,0 \
    -r 48000 \
    -F S32_LE \
    -c 2 \
    -t sine \
    -f 1000 \
    -p 1000
```

Basic capture using a 48-frame period:

```bash
arecord \
    -D hw:RAVENNA,0 \
    -r 48000 \
    -f S32_LE \
    -c 2 \
    -t raw \
    --period-size=48 \
    --buffer-size=1536 \
    capture.raw
```

The exact ALSA card index/name may differ between hosts.

## Troubleshooting

### Butler process is running but TCP 9090 is not listening

Verify that the host-local `Butler/merging_ravenna_daemon.conf` contains
a valid `device_name` and uses the simple `key=value` layout generated by
`ravenna_check_and_run.sh`. During validation, the known-good local
configuration included both the selected RAVENNA interface and a unique
device name, after which Butler completed initialization and exposed the
web interface normally.


### Butler reports `Add RTP stream invalid data size`

The module was probably built without the legacy RTP adapter. Rebuild with:

```bash
make clean
make -j"$(nproc)" BUTLER_1193_COMPAT=1
```

and reload the module before restarting Butler.

### Butler does not display PTP status

Check that the compatibility build is loaded when using Butler 1.1.93, and verify PTP traffic on the selected interface. Butler 1.1.93 requires the legacy 16-byte PTP reply.

### Butler fails on `CURL_OPENSSL_3`

Run `Butler/patch_curl_openssl4.py` and execute the generated copy. Do not replace system libraries globally.

### Session Sink shows a broken `Started` icon

The required file is `Butler/webapp/advanced/images/network-started.png`. It is included in this branch. If an older local checkout is being used, update the branch and hard-refresh the browser cache.

### Same-host Source-to-Sink test captures silence

Do not infer a receive-path failure from a same-interface local loop. The driver's receive hook is on physical ingress. Use a real external sender or a second physical interface so the multicast packet actually re-enters the RX interface.

### Sources are not discovered

Verify mDNS/SAP multicast traffic, IGMP membership, switch snooping configuration and host firewall rules.

## Further documentation

- [`docs/ubuntu-26.04-kernel7-butler-1.1.93.md`](docs/ubuntu-26.04-kernel7-butler-1.1.93.md) — detailed compatibility implementation and validation record.
- [Merging Technologies RAVENNA/AES67 documentation](https://confluence.merging.com/)
- [Real-time Audio on Embedded Linux](https://elinux.org/images/8/82/Elc2011_lorriaux.pdf)
- [Tools and techniques for audio debugging](http://www.ti.com/lit/an/sprac10/sprac10.pdf)

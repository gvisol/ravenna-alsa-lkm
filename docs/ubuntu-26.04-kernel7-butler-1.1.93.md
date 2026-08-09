# Ubuntu 26.04 / Linux 7.x + Merging Butler 1.1 build 93

This note documents the compatibility work validated on Ubuntu 26.04 LTS with
Linux `7.0.0-29-generic`, x86-64, using the `aes67-daemon` branch.

## What works

The v2.1 driver builds and loads on Linux 7.0.0-29, exposes the RAVENNA ALSA
playback/capture device, receives PTP on the selected Ethernet interface, locks
to the Grandmaster, and can be controlled by Merging Butler 1.1 build 93 after the
compatibility adaptations described below.

Validated observations included:

- `MergingRavennaALSA.ko` builds successfully against 7.0.0-29 headers.
- ALSA exposes RAVENNA playback and capture devices.
- Butler initialises successfully and serves its web UI on TCP 9090.
- PTP Sync, Follow_Up and Announce are received on domain 0.
- The kernel PTP state transitions `UNLOCKED -> LOCKING -> LOCKED`.
- Butler's PTP page displays status once the legacy PTP Netlink ABI shim is
  enabled.
- Butler 1.1.93 Session Sources and Session Sinks can both create RTP streams
  through the legacy 402-byte to v2.1 403-byte Add-RTP compatibility adapter.
- RTP receive has been validated from physical multicast ingress through the
  driver to two-channel ALSA capture.

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
| `i32Jitter` | modern `i32ClockJitter` (`m_maxClkJitter`), in microseconds |

A normal build without `BUTLER_1193_COMPAT=1` retains the upstream v2.1
36-byte ABI and remains suitable for software that understands the newer
structure. The legacy compatibility object is not compiled or linked in a
normal build.

### Legacy PTP jitter telemetry

Butler 1.1.93 consumes the third field of its 16-byte PTP status structure as
`Jitter`. The compatibility adapter maps this field to the v2.1
`i32ClockJitter` statistic.

The driver computes this value in microseconds. In `timerProcess()` the
instantaneous value is calculated as the scheduled audio-frame TIC time minus
the current clock time:

```text
clkJitter = scheduled_TIC_time - current_clock_time
```

`m_maxClkJitter` keeps the maximum positive value observed during the reporting
interval. Because it is initialised/reset to zero and updated with `max()`,
negative values are not retained. `GetPTPStatus()` publishes this statistic
through `i32ClockJitter` and resets the maximum for the next interval.

The legacy Butler web UI labels this series `Delta`. It should therefore be
interpreted as the driver's TIC clock-jitter statistic, in microseconds, not as
IEEE 1588 `offsetFromMaster`.

For example, a displayed value of `406` corresponds to a maximum reported
`clkJitter` of `406 us` (`0.406 ms`) during that reporting interval.

### Legacy RTP stream creation ABI

The ST 2022-7 driver update also changed the packed `TRTP_stream_info`
structure used by `MT_ALSA_Msg_Add_RTPStream`. Driver v2.0+ inserted:

```c
bool m_bIsPrimaryPort;
```

immediately before `m_aui32Routing[]`.

Because the structure is packed, this changes its size:

| ABI | `TRTP_stream_info` size |
| --- | ---: |
| Butler 1.1.93 / pre-ST-2022-7 | 402 bytes |
| driver v2.0+ / v2.1 | 403 bytes |

Without compatibility translation, the current driver rejects the request
before RTP stream creation and logs:

```text
Add RTP stream invalid data size
```

When `BUTLER_1193_COMPAT=1` is enabled, incoming legacy Add-RTP messages are
intercepted before the normal v2.1 Netlink handler.

The compatibility adapter:

1. Accepts only the exact legacy 402-byte representation.
2. Verifies the embedded legacy structure size.
3. Copies the common packed prefix.
4. Inserts the new `m_bIsPrimaryPort` field.
5. Copies `m_aui32Routing[]` explicitly to its shifted v2.1 offset.
6. Changes the embedded structure size to 403 bytes.
7. Changes the Netlink payload size to 403 bytes.
8. Calls the original v2.1 `nl_rx_msg()` implementation.

The routing array must be copied explicitly. Reinterpreting the old 402-byte
layout directly as the new 403-byte structure would shift and corrupt the
routing entries after the inserted ST 2022-7 field.

For the validated single-NIC configuration, legacy interface 0 is represented
as the primary port. Butler 1.1.93 cannot express the complete ST 2022-7
primary/secondary dual-interface semantics, so this compatibility mode must
not be interpreted as full legacy-Butler ST 2022-7 support.

The validated RTP TX source used:

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
```

The observed packetisation was:

```text
48 samples * 2 channels * 3 bytes = 288 bytes audio
12 bytes RTP header                =  12 bytes
                                      ---------
UDP payload                        = 300 bytes
```

Successive packets incremented the RTP sequence number by one and the RTP
timestamp by 48 samples.

With ALSA idle, the RTP source continued transmitting packets containing
silence. During a 1 kHz `speaker-test`, the RTP payload contained non-zero L24
audio samples while preserving the same packet size and RTP timing.

This validates the tested ALSA -> driver -> PTP-paced RTP -> L24 network TX
path. It is not intended as a complete AES67 conformance certification.


### RTP RX validation with Butler Session Sink

The same legacy Add-RTP compatibility path used for Session Sources was also
validated with Butler 1.1.93 Session Sinks.

When Butler created the sink, the kernel logged the compatibility translation
followed by successful sink creation:

```text
Butler 1.1.93 compat: translated Add RTP stream 402 -> 403 bytes (if=0 primary=1 channels=2)
CRTP_streams_manager::AddRTPStream: Add sink ...
```

The sink joined multicast group `239.1.0.252`, confirming that the translated
stream description reached the receive-side RTP configuration.

The validated receive stream used:

```text
multicast         239.1.0.252:5004
source            172.30.0.253
sample rate       48000 Hz
codec             L24
channels          2
samples/packet    48
packet period     1 ms
payload type      98
PTP domain        0
```

Relevant SDP attributes were:

```text
c=IN IP4 239.1.0.252/15
m=audio 5004 RTP/AVP 98
a=rtpmap:98 L24/48000/2
a=source-filter: incl IN IP4 239.1.0.252 172.30.0.253
a=clock-domain:PTPv2 0
a=framecount:48
a=ptime:1
a=ts-refclk:ptp=traceable
a=mediaclk:direct=0
a=recvonly
```

#### Physical RX test topology

A same-interface local loopback was shown not to provide a valid physical RX
test for this driver.

The RTP Source transmitted correctly through `eno1`, but directional packet
capture showed:

```text
RTP packets observed as eno1 TX: 4001
RTP packets observed as eno1 RX:    0
```

To provide real physical ingress, a second Ethernet interface on the same host
was connected to the same Layer-2 network:

```text
RAVENNA RX interface     eno1               172.30.0.252
physical relay TX        enx4ccf7c35822f    172.30.0.253
PTP Grandmaster                              172.30.0.254
```

The test path was:

```text
ALSA playback
    ->
RAVENNA Source
    ->
eno1 TX
    ->
RTP relay preserving original RTP packet
    ->
enx4ccf7c35822f / 172.30.0.253
    ->
Ethernet switch
    ->
eno1 physical RX
    ->
RAVENNA Session Sink
    ->
ALSA capture
```

The relay preserved the original RTP header and audio payload, including:

- RTP sequence number
- RTP timestamp
- SSRC
- payload type 98
- L24 audio payload

Only the outer UDP/IP source was regenerated from `172.30.0.253`.

This allowed the RX path to be exercised with the RTP timestamps produced by
the PTP/SAC-aware RAVENNA TX implementation instead of using arbitrary
timestamps from a synthetic generator.

Physical ingress on `eno1` was confirmed:

```text
172.30.0.253.5004 > 239.1.0.252.5004: UDP, length 300

4001 packets captured
4001 packets received by filter
0 packets dropped by kernel
```

Packet cadence remained approximately one packet every millisecond.

The relayed RTP timestamp advanced by exactly 48000 samples for every 1000
packets:

```text
1000 packets -> timestamp 3102121008
2000 packets -> timestamp 3102169008
3000 packets -> timestamp 3102217008
4000 packets -> timestamp 3102265008
```

Therefore:

```text
1000 packets * 48 samples = 48000 samples = 1 second at 48 kHz
```

#### ALSA capture validation

With physical RTP ingress active, `arecord` captured the RAVENNA ALSA device
as two-channel `S32_LE` at 48 kHz.

The resulting capture contained:

```text
bytes       = 3075072
frames      = 384384

CH1 nonzero = 143999
CH1 peak    = 1721678592
CH1 RMS     = 745125057.6958936

CH2 nonzero = 94656
CH2 peak    = 1721678592
CH2 RMS     = 604132725.1389692
```

Unlike the earlier same-interface test, the physical-ingress capture therefore
contained real non-zero audio on both channels.

A 250 ms high-energy section from each channel was analysed independently:

```text
CH1
  RMS                 = 1217760574.1
  peak                = 1721678592
  frequency estimate  = 1000.083 Hz

CH2
  RMS                 = 1217751849.8
  peak                = 1721678592
  frequency estimate  = 1000.083 Hz
```

The stimulus generated by `speaker-test` was 1 kHz.

The small difference between `1000.083 Hz` and `1000 Hz` is consistent with
the finite-window zero-crossing estimator used for the measurement.

The maximum-energy regions occurred at different times for channel 1 and
channel 2, which is also consistent with `speaker-test` exercising stereo
channels sequentially.

The following path is therefore functionally validated:

```text
physical Ethernet RX
    ->
IPv4 / UDP / RTP
    ->
Butler-created RAVENNA Session Sink
    ->
RTP L24 depacketisation
    ->
RAVENNA input buffers and routing
    ->
ALSA S32_LE capture
    ->
arecord
```

This confirms that the Butler 1.1.93 402-byte Add-RTP compatibility adapter is
valid for both RTP Source and RTP Sink creation in the tested single-interface
RAVENNA configuration.

#### ALSA capture negotiation note

During the successful RX test, ALSA capture negotiated:

```text
sample rate       48000
channels          2
format            S32_LE
period_size       384
PTP frame size    48
periods           62
```

The driver reported:

```text
periodSize (384) differs from ptp_frame_size (48)
nbPeriods (62) differs from expected (1024)
bufferSize (24000) differs from expected (2976)
```

These diagnostics did not prevent correct two-channel RTP reception or ALSA
capture.

Period and buffer negotiation should therefore be investigated separately as
an ALSA latency/configuration optimisation issue, rather than as a Butler
1.1.93 ABI compatibility failure.

#### Validation scope

The tests establish functional compatibility for the tested path:

```text
Butler 1.1.93
PTP lock
ALSA playback
RTP/L24 TX
physical multicast transport
RTP/L24 RX
ALSA capture
```

This is not a complete AES67 or RAVENNA conformance certification.

The validation does not yet cover:

- long-duration stability
- packet-loss recovery
- deliberately impaired network jitter
- redundant ST 2022-7 operation
- exhaustive interoperability with independent third-party senders

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

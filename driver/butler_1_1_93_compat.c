#define BUTLER_1_1_93_COMPAT_IMPLEMENTATION

#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/stddef.h>

#include "butler_1_1_93_compat.h"
#include "c_wrapper_lib.h"
#include "audio_streamer_clock_PTP_defs.h"
#include "RTP_stream_info.h"
#include "module_main.h"
#include "../common/MT_ALSA_message_defs.h"

/*
 * Legacy packed PTP status layout used by Merging Butler 1.1 build 93.
 */
struct __attribute__((packed)) TPTPStatus_1_1_93
{
    int32_t  nPTPLockStatus;
    uint64_t ui64GMID;
    int32_t  i32Jitter;
};

/*
 * Legacy packed RTP stream description used before ST-2022-7.
 *
 * Driver v2.0 inserted:
 *
 *     bool m_bIsPrimaryPort;
 *
 * immediately before m_aui32Routing[].
 *
 * Consequently:
 *
 *     legacy Butler 1.1.93 : 402 bytes
 *     current driver v2.1 : 403 bytes
 */
struct __attribute__((packed)) TRTP_stream_info_1_1_93
{
    uint32_t       m_ui32CRTP_stream_info_sizeof;

    int8_t         m_b802_1Q;
    int16_t        m_ui16VLAN_Id;

    unsigned int   m_uiIfPortId;

    char           m_cName[MAX_STREAM_NAME_SIZE];

    uint32_t       m_ui32PlayOutDelay;
    uint32_t       m_ui32FrameSize;
    uint32_t       m_ui32MaxSamplesPerPacket;

    uint8_t        m_ui8DestMAC[6];

    unsigned char  m_ucDSCP;
    uint32_t       m_ui32RTCPSrcIP;
    uint32_t       m_ui32SrcIP;
    uint32_t       m_ui32DestIP;
    unsigned char  m_byTTL;

    unsigned short m_usSrcPort;
    unsigned short m_usDestPort;

    unsigned short m_usRTCPSrcPort;
    unsigned short m_usRTCPDestPort;

    unsigned char  m_byPayloadType;
    uint32_t       m_ui32SSRC;
    int8_t         m_bSSRCInitialized;

    uint32_t       m_ui32RTPTimestampOffset;

    uint32_t       m_ui32SamplingRate;
    char           m_cCodec[MAX_CODEC_NAME_SIZE];
    unsigned char  m_byWordLength;
    unsigned char  m_byNbOfChannels;
    int8_t         m_bSource;

    unsigned int   m_uiId;

    uint32_t       m_aui32Routing[MAX_CHANNELS_BY_RTP_STREAM];
};


/*
 * kernel -> Butler compatibility.
 */
int butler_1_1_93_send_reply_to_user_land(void *msg_void)
{
    struct MT_ALSA_msg *msg = (struct MT_ALSA_msg *)msg_void;

    if (msg != NULL &&
        msg->id == MT_ALSA_Msg_GetPTPStatus &&
        msg->errCode == 0 &&
        msg->data != NULL &&
        msg->dataSize == sizeof(TPTPStatus))
    {
        const TPTPStatus *status = (const TPTPStatus *)msg->data;
        struct TPTPStatus_1_1_93 legacy_status;
        struct MT_ALSA_msg legacy_msg = *msg;

        legacy_status.nPTPLockStatus =
            (int32_t)status->nPTPLockStatus;

        legacy_status.ui64GMID =
            status->ui64GMID[0];

        /*
         * Butler 1.1.93 consumes this legacy field as PTP "Jitter".
         * Feed it from the v2.1 clock-jitter statistic so legacy PTP
         * telemetry remains functional.
         */
        legacy_status.i32Jitter =
            status->i32ClockJitter;

        legacy_msg.dataSize = sizeof(legacy_status);
        legacy_msg.data = &legacy_status;

        return CW_netlink_send_reply_to_user_land(&legacy_msg);
    }

    return CW_netlink_send_reply_to_user_land(msg_void);
}


/*
 * Butler -> kernel compatibility.
 */
void butler_1_1_93_nl_rx_msg(void *msg_void)
{
    struct MT_ALSA_msg *msg = (struct MT_ALSA_msg *)msg_void;

    if (msg != NULL &&
        msg->id == MT_ALSA_Msg_Add_RTPStream &&
        msg->data != NULL &&
        msg->dataSize == sizeof(struct TRTP_stream_info_1_1_93))
    {
        const struct TRTP_stream_info_1_1_93 *legacy;
        TRTP_stream_info current_info;
        struct MT_ALSA_msg translated_msg;
        uint32_t embedded_size;

        legacy =
            (const struct TRTP_stream_info_1_1_93 *)msg->data;

        memcpy(&embedded_size,
               &legacy->m_ui32CRTP_stream_info_sizeof,
               sizeof(embedded_size));

        /*
         * Only translate the exact legacy ABI.  Do not reinterpret an
         * unknown future or corrupted structure.
         */
        if (sizeof(struct TRTP_stream_info_1_1_93) != 402 ||
            sizeof(TRTP_stream_info) != 403 ||
            embedded_size != sizeof(struct TRTP_stream_info_1_1_93))
        {
            printk(KERN_ERR
                   "Butler 1.1.93 compat: unexpected RTP ABI "
                   "(legacy=%zu current=%zu embedded=%u)\n",
                   sizeof(struct TRTP_stream_info_1_1_93),
                   sizeof(TRTP_stream_info),
                   embedded_size);

            nl_rx_msg(msg_void);
            return;
        }

        memset(&current_info, 0, sizeof(current_info));

        /*
         * Everything before m_bIsPrimaryPort has identical packed
         * layout in the legacy and current structures.
         */
        memcpy(&current_info,
               legacy,
               offsetof(TRTP_stream_info, m_bIsPrimaryPort));

        /*
         * A legacy Butler stream has no ST-2022-7 secondary-port
         * semantics. Interface 0 is therefore represented as the
         * primary stream.
         */
        current_info.m_bIsPrimaryPort =
            (legacy->m_uiIfPortId == 0);

        /*
         * In the legacy structure routing[] starts exactly where the
         * current structure inserted m_bIsPrimaryPort. Copy routing
         * explicitly so it is shifted to its correct v2.1 offset.
         */
        memcpy(current_info.m_aui32Routing,
               legacy->m_aui32Routing,
               sizeof(current_info.m_aui32Routing));

        /*
         * The driver performs its own structure-version check after
         * the Netlink size check, so advertise the translated v2.1
         * structure size.
         */
        current_info.m_ui32CRTP_stream_info_sizeof =
            sizeof(TRTP_stream_info);

        translated_msg = *msg;
        translated_msg.dataSize = sizeof(TRTP_stream_info);
        translated_msg.data = &current_info;

        printk(KERN_INFO
               "Butler 1.1.93 compat: translated Add RTP stream "
               "%zu -> %zu bytes (if=%u primary=%u channels=%u)\n",
               sizeof(struct TRTP_stream_info_1_1_93),
               sizeof(TRTP_stream_info),
               current_info.m_uiIfPortId,
               current_info.m_bIsPrimaryPort ? 1 : 0,
               current_info.m_byNbOfChannels);

        nl_rx_msg(&translated_msg);
        return;
    }

    nl_rx_msg(msg_void);
}

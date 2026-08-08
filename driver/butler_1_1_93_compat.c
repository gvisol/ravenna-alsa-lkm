#include "c_wrapper_lib.h"
#include "audio_streamer_clock_PTP_defs.h"
#include "../common/MT_ALSA_message_defs.h"

/* Legacy packed layout used by Merging Butler 1.1 build 93. */
struct __attribute__((packed)) TPTPStatus_1_1_93
{
    int32_t  nPTPLockStatus;
    uint64_t ui64GMID;
    int32_t  i32Jitter;
};

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

        legacy_status.nPTPLockStatus = (int32_t)status->nPTPLockStatus;
        legacy_status.ui64GMID = status->ui64GMID[0];

        /* Preserve the exact 1.1.93 behaviour: this field was TODO/zero. */
        legacy_status.i32Jitter = 0;

        legacy_msg.dataSize = sizeof(legacy_status);
        legacy_msg.data = &legacy_status;

        return CW_netlink_send_reply_to_user_land(&legacy_msg);
    }

    return CW_netlink_send_reply_to_user_land(msg_void);
}

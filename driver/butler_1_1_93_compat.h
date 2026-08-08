#ifndef BUTLER_1_1_93_COMPAT_H
#define BUTLER_1_1_93_COMPAT_H

/*
 * Build-time compatibility hook for the proprietary Merging Butler
 * 1.1 build 93 binary.
 *
 * manager.c normally replies with the v2.0+ TPTPStatus structure (36 bytes).
 * Butler 1.1.93 hard-codes the legacy 16-byte layout and rejects the newer
 * reply before copying it.  Redirect only manager.c's Netlink reply function
 * through a small adapter; the internal driver structures and PTP engine stay
 * unchanged.
 */
int butler_1_1_93_send_reply_to_user_land(void *msg);
#define CW_netlink_send_reply_to_user_land butler_1_1_93_send_reply_to_user_land

#endif /* BUTLER_1_1_93_COMPAT_H */

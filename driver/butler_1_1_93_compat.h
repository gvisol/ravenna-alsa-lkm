#ifndef BUTLER_1_1_93_COMPAT_H
#define BUTLER_1_1_93_COMPAT_H

/*
 * Build-time compatibility hook for the proprietary Merging Butler
 * 1.1 build 93 binary.
 *
 * manager.c normally replies with the v2.0+ TPTPStatus structure (36 bytes).
 * Butler 1.1.93 hard-codes the legacy 16-byte layout and rejects the newer
 * reply before copying it. Redirect only manager.c's Netlink reply function
 * through a small adapter; the internal driver structures and PTP engine stay
 * unchanged.
 */
int butler_1_1_93_send_reply_to_user_land(void *msg);

/*
 * manager.c is compiled with this header force-included. Do not apply the
 * redirection while compiling the adapter implementation itself, otherwise
 * its call to the original Netlink function would recurse back into itself.
 */
#ifndef BUTLER_1_1_93_COMPAT_IMPLEMENTATION
#define CW_netlink_send_reply_to_user_land \
    butler_1_1_93_send_reply_to_user_land
#endif

#endif /* BUTLER_1_1_93_COMPAT_H */

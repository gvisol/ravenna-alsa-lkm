#ifndef BUTLER_1_1_93_COMPAT_H
#define BUTLER_1_1_93_COMPAT_H

/*
 * Build-time compatibility hooks for the proprietary Merging Butler
 * 1.1 build 93 binary.
 *
 * Butler 1.1.93 predates the ST-2022-7 Netlink ABI changes introduced
 * in driver v2.0.
 *
 * Compatibility currently provided:
 *
 *   kernel -> Butler:
 *     TPTPStatus v2.1 (36 bytes) -> legacy 1.1.93 layout (16 bytes)
 *
 *   Butler -> kernel:
 *     TRTP_stream_info legacy (402 bytes) -> v2.1 layout (403 bytes)
 *
 * The normal v2.1 driver ABI remains untouched unless the module is
 * explicitly built with:
 *
 *     BUTLER_1193_COMPAT=1
 */

int butler_1_1_93_send_reply_to_user_land(void *msg);
void butler_1_1_93_nl_rx_msg(void *msg);

/*
 * manager.c and module_netlink.c are force-included with this header
 * only in a BUTLER_1193_COMPAT build.
 *
 * Do not redirect calls made by the adapter implementation itself,
 * otherwise the wrappers would recurse into themselves.
 */
#ifndef BUTLER_1_1_93_COMPAT_IMPLEMENTATION

#define CW_netlink_send_reply_to_user_land \
    butler_1_1_93_send_reply_to_user_land

#define nl_rx_msg \
    butler_1_1_93_nl_rx_msg

#endif

#endif /* BUTLER_1_1_93_COMPAT_H */

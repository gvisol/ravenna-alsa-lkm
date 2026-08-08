#####################################################################################################
# Makefile for the Linux Kernel Module for Merging Ravenna ALSA driver
# This will build MergingRavennaALSA.ko
#####################################################################################################

obj-m := MergingRavennaALSA.o
MergingRavennaALSA-objs := c_wrapper_lib.o audio_driver.o manager.o module_main.o PTP.o module_interface.o module_netlink.o module_timer.o EtherTubeNetfilter.o RTP_streams_manager.o RTP_audio_stream.o RTP_stream.o RTP_stream_info.o MTAL_EthUtils.o MTAL_LKernelAPI.o MTConvert.o

# Merging Butler 1.1 build 93 predates the ST-2022-7 Netlink ABI changes:
#
#   TPTPStatus      : 16 bytes legacy -> 36 bytes in driver v2.0+
#   TRTP_stream_info: 402 bytes legacy -> 403 bytes in driver v2.0+
#
# Keep the modern driver ABI by default and enable the compatibility shim only
# when this module is built for the legacy Butler binary:
#
#   make BUTLER_1193_COMPAT=1
#
BUTLER_1193_COMPAT ?= 0
ifeq ($(BUTLER_1193_COMPAT),1)
MergingRavennaALSA-objs += butler_1_1_93_compat.o
CFLAGS_manager.o += -include $(src)/butler_1_1_93_compat.h
CFLAGS_module_netlink.o += -include $(src)/butler_1_1_93_compat.h
endif

MAKE = make
KERNELRELEASE = $(shell uname -r)
KSRC = /lib/modules/$(KERNELRELEASE)/build/
SRC = $(shell pwd)

modules:
	$(MAKE) -C $(KSRC) M=$(SRC) BUTLER_1193_COMPAT=$(BUTLER_1193_COMPAT) modules

modules_install:
	$(MAKE) -C $(KSRC) M=$(SRC) BUTLER_1193_COMPAT=$(BUTLER_1193_COMPAT) modules_install

clean:
	$(MAKE) -C $(KSRC) M=$(SRC) clean

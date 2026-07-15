KDIR ?= /lib/modules/$(shell uname -r)/build
CXL_NODE ?= 1
MEMORY_ALLOC_NODE ?= 0

obj-m += pac_ofw_buf.o
PWD := $(CURDIR)
ccflags-y += -DCXL_NODE=$(CXL_NODE) -DMEMORY_ALLOC_NODE=$(MEMORY_ALLOC_NODE)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

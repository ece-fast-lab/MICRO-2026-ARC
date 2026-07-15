obj-m += page_migrate.o

KDIR ?= /lib/modules/$(shell uname -r)/build
CXL_MEM_PFN_BEGIN ?= 0x2080000
CXL_MEM_NUM_PFN ?= 2097152
PWD := $(CURDIR)
ccflags-y += -DCXL_MEM_PFN_BEGIN=$(CXL_MEM_PFN_BEGIN) -DCXL_MEM_NUM_PFN=$(CXL_MEM_NUM_PFN)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>
#include <thread>
#include <vector>
#include <fcntl.h>
#include <sys/mman.h>
#include <cstring> // Required for memset
#include <x86intrin.h>
#include <cerrno>

#include "util.h"
#include "csr.h"
#include "worker.h"

#define SLEEP_SEC 1

int init(int* pci_fd, uint64_t** pci_vaddr, bool hw_reset,
            uint32_t** pac_ofw_buf_vaddr, uint64_t* pac_ofw_buf_paddr) {

    int         kmod_fd_dst, kmod_fd_src;
    int         init_ok;
    ssize_t     bytes_read;
    uint64_t*   pci_vaddr_ptr;

    // Default: PAC OFW buffer disabled unless successfully opened + mmap'd
    if (pac_ofw_buf_vaddr) *pac_ofw_buf_vaddr = nullptr;
    if (pac_ofw_buf_paddr) *pac_ofw_buf_paddr = 0;

    /* Initialize CSR access */
    init_ok = init_csr(pci_fd, &(*pci_vaddr));
    if (init_ok) {
        LOG_ERROR(" Failed with init csr.\n");
        goto FAILED;
    }

    pci_vaddr_ptr = *pci_vaddr;
    // Hardware reset for PAC OFW buffer (CSR[26])
    if (hw_reset) {
        LOG_INFO("Performing hardware reset of PAC OFW buffer (CSR[26])...\n");
        pci_vaddr_ptr[CSR_PAC_OFW_RESET] = 1;  // Trigger reset
        usleep(1000);  // Wait 1ms for reset to complete
        pci_vaddr_ptr[CSR_PAC_OFW_RESET] = 0;  // Clear reset
        LOG_INFO("Hardware reset complete.\n");
    }


    // pac_ofw_buf (optional)
    // This buffer is only required for PAC dump modes. For normal migration, we allow running without it.
    LOG_INFO("Opening /proc/pac_ofw_buf ...\n");
    kmod_fd_dst = open("/proc/pac_ofw_buf", O_RDWR);
    if (kmod_fd_dst == -1) {
        LOG_WARN(" pac_ofw_buf not available (%s). Continue without PAC OFW buffer.\n",
                 std::strerror(errno));
        return 0;
    }

    if ((bytes_read = read(kmod_fd_dst, pac_ofw_buf_paddr, sizeof(uint64_t))) < 0) {
        LOG_WARN(" Read pac_ofw_buf_paddr failed (%s). Continue without PAC OFW buffer.\n",
                 std::strerror(errno));
        close(kmod_fd_dst);
        if (pac_ofw_buf_vaddr) *pac_ofw_buf_vaddr = nullptr;
        if (pac_ofw_buf_paddr) *pac_ofw_buf_paddr = 0;
        return 0;
    }

    LOG_INFO(" pac_ofw_buf_paddr read from the proc is 0x%lx (size=%ld)\n", *pac_ofw_buf_paddr, bytes_read);
    LOG_INFO(" pci_vaddr_ptr[CSR_PAC_OFW_BUF_HEAD] = 0x%lx\n", pci_vaddr_ptr[CSR_PAC_OFW_BUF_HEAD]);

    // Map the contiguous buffer to user's memory space
    *pac_ofw_buf_vaddr = (uint32_t*)mmap(NULL, BUF_SIZE_BYTE, PROT_READ | PROT_WRITE,
                                        MAP_SHARED, kmod_fd_dst, 0);
    if (*pac_ofw_buf_vaddr == (void*)-1 || *pac_ofw_buf_vaddr == (void*)0) {
        LOG_WARN(" PAC_OFW buffer mmap failed (%s). Continue without PAC OFW buffer.\n",
                 std::strerror(errno));
        close(kmod_fd_dst);
        if (pac_ofw_buf_vaddr) *pac_ofw_buf_vaddr = nullptr;
        if (pac_ofw_buf_paddr) *pac_ofw_buf_paddr = 0;
        return 0;
    }

    // fd can be closed after mmap; mapping stays valid
    close(kmod_fd_dst);

    pci_vaddr_ptr[CSR_PAC_OFW_BUF_MAX] = BUF_SIZE_BYTE / 64;

    // Fill with sentinel pattern (0xFF) instead of zeros.
    // This lets software distinguish "FPGA wrote raw=0" from "FPGA never wrote here".
    memset(*pac_ofw_buf_vaddr, 0xFF, BUF_SIZE_BYTE);

    if (hw_reset) {
        pci_vaddr_ptr[CSR_PAC_OFW_BUF_HEAD] = *pac_ofw_buf_paddr;
        LOG_INFO(" hw_reset: Set HEAD to buffer base paddr: 0x%lx\n", *pac_ofw_buf_paddr);
    }
    LOG_INFO(" pci_vaddr_ptr[CSR_PAC_OFW_BUF_HEAD] = 0x%lx\n", pci_vaddr_ptr[CSR_PAC_OFW_BUF_HEAD]);

    for (int i = 0; i < BUF_SIZE_BYTE; i += 64) {
        _mm_clflush((char*)(*pac_ofw_buf_vaddr) + i);
    }
    _mm_mfence();
    return 0;

FAILED:
    return -1;
}


void set_default_cfg(cfg_t& cfg) {
    cfg.wait_ms = 200;              // 200ms default for migration polling
    cfg.is_test = false;
    cfg.print_list = false;
    cfg.print_counter = false;
    cfg.is_traffic = false;
    cfg.is_traffic_rate = -1;
    cfg.parsing_mode = false;
    cfg.do_dump = false;
    cfg.eac_migration = false;
    cfg.hw_reset = false;
    cfg.separate_dump = false;
    cfg.target_pid = 0;
    cfg.migration_interval_ms = 0;
    cfg.pfn_offset = 0x80000;       // system PFN = CHMU PFN - offset
    cfg.max_migrated_pfns = 250000; // dedup table cap (0 = unlimited)
    cfg.enable_epoch_toggle = false;
    cfg.epoch_cycle_a = 0;
    cfg.epoch_cycle_b = 0;
    cfg.epoch_toggle_interval_ms = 100;
}

int main(int argc, char **argv){
    uint64_t* pci_vaddr;
    uint64_t pac_ofw_buf_paddr;
    uint32_t* pac_ofw_buf_vaddr;

    int ret, pci_fd;
    cfg_t cfg;

    // arg parse?
    set_default_cfg(cfg);
    ret = parse_arg(argc, argv, cfg);
    IF_FAIL_THEN_EXIT

    // init csr
    ret = init(&pci_fd, &pci_vaddr, cfg.hw_reset, &pac_ofw_buf_vaddr, &pac_ofw_buf_paddr);
    IF_FAIL_THEN_EXIT


    // If PAC OFW buffer is required (dump modes) but unavailable, fail fast.
    if ((cfg.do_dump || cfg.separate_dump) && pac_ofw_buf_vaddr == nullptr) {
        LOG_ERROR("PAC OFW buffer is required for -d (dump) or -S (separate dump), but /proc/pac_ofw_buf is unavailable.\n");
        LOG_ERROR("Load pac_ofw_buf module or run without dump modes.\n");
        clean_csr(pci_fd, pci_vaddr);
        return -1;
    }

    // start migration or dump threads
    ret = start_threads(pci_vaddr, cfg, pac_ofw_buf_paddr, pac_ofw_buf_vaddr);

    // clean up
    clean_csr(pci_fd, pci_vaddr);
    if (ret != 0) {
        LOG_ERROR("Migration manager failed.\n");
        return ret;
    }
    LOG_INFO("Done.\n");
    return 0;
}

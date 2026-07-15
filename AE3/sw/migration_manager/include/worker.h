#ifndef WORKER_H
#define WORKER_H

#include <iostream>
#include <thread>
#include <vector>
#include <fstream>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <queue>
#include <csignal>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <iomanip>
#include "util.h"


#define PATH_TO_MIGRATION_PFN   "/proc/cxl_migrate_pfn"
#define PATH_TO_MIGRATION_NODE  "/proc/cxl_migrate_node"

// TODO, make this arg?
#ifndef MIGRATION_TARGET_NODE
#define MIGRATION_TARGET_NODE   0
#endif

using std::vector;
using std::thread;
using std::cout;
using std::endl;
using std::cerr;
using std::string;
using std::ofstream;
using std::unique_lock;
using std::mutex;
using std::shared_ptr;
using std::condition_variable;

int start_threads(uint64_t* pci_vaddr, cfg_t cfg, uint64_t pac_ofw_buf_paddr, uint32_t* pac_ofw_buf_vaddr);

int run_kmod_migration(uint64_t* pci_vaddr, cfg_t& cfg);

#endif

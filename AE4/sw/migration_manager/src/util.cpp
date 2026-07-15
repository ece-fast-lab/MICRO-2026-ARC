#include "util.h"
#include <stdio.h>
#include <numa.h>
#include <numaif.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>

void print_arr(uint64_t* arr, int len) {
    for (int i = 0; i < len; i++) {
        cout << i << " " << arr[i] << "   ";
        if (len % 16 == 0 && len != 0) {
            cout << endl;
        }
    }
    cout << endl;
}

void print_unordered_map(unordered_map<uint64_t, uint64_t>& map) {
    int i = 0;
    for (const auto& pair : map) {
        //if (pair.second == 0) continue;
        if (i % 8 == 0) cout << i << " ";
        cout << "{" << std::hex << pair.first << ":" <<  std::dec << pair.second << "}   ";
        if (i % 8 == 7) cout << endl;
        i++;
        if (i == 256) break;
    }
    cout << endl;
}

void print_arr_hex(uint64_t* arr, int len) {
    for (int i = 0; i < len; i++) {
        if (i % 8 == 0) cout << i << " ";
        cout << std::hex << arr[i] <<  std::dec << "   ";
        if (i % 8 == 7) cout << endl;
    }
    cout << endl;
}

void print_map(unordered_map<uint64_t, uint64_t>& map) {
    for (auto it = map.cbegin(); it != map.cend(); ++it) {
        cout << std::hex << it->first <<  std::dec << " " << it->second << endl;
    }
}

// This function returns the NUMA node that a pointer address resides on.
int get_node(void *p, uint64_t size)
{
	int* status;
	void** page_arr;
	unsigned long page_size;
	unsigned long page_cnt;
	int ret;
	char* start_addr;

	page_size = (unsigned long)getpagesize();
	page_cnt = (size / page_size);
	status = (int*)malloc(page_cnt * sizeof(int));
	page_arr = (void**)malloc(page_cnt * sizeof(char*));
	start_addr = (char*)p;

	fprintf(stdout, "[get_node] buf: %lx, page_size: %ld, page_cnt: %ld\n", (uint64_t)(p), page_size, page_cnt);

	for (unsigned long i = 0; i < page_cnt; i++) {
		page_arr[i] = start_addr;
		if (i < page_cnt) {
			start_addr = &(start_addr[page_size]);
		}
	}


	ret = move_pages(0, page_cnt, page_arr, NULL, status, 0);
	if (ret != 0) {
		fprintf(stderr, "Problem in %s line %d calling move_pages(), ret = %d\n", __FILE__,__LINE__, ret);
		printf("%s\n", strerror(errno));
	}

	ret = status[0];
	for (uint64_t i = 0; i < page_cnt; i++) {
		if (ret != status[i]) {
			fprintf(stderr, "found page: %lu on node: %d, different from node: %d\n", i, status[i], ret);
			ret = status[i];
			break;
		}
	}

	if (ret == status[0]) {
		fprintf(stdout, "all pages: %lx, %lx ... are on node: %d\n", (uint64_t)(page_arr[0]), (uint64_t)(page_arr[1]), ret);
	}

	free(page_arr);
	free(status);
	return ret;
}

/**
 * node_alloc
 *   @brief Allocate a memory buffer on the specified node.
 *   @param size in unit of bytes
 *   @param node integer to indicate the node where to allocate.
 *   @param alloc_ptr used for returning the pointer to the buffer.
 *   @return 0 if successful. Else error.
 */
int node_alloc(uint64_t size, int node, char** alloc_ptr, bool touch_pages) {
    char *ptr;
    int ret;
    unsigned long page_size;
    uint64_t page_cnt;
    uint64_t idx;

    if ((ptr = (char *)numa_alloc_onnode(size, node)) == NULL) {
        fprintf(stderr,"Problem in %s line %d allocating memory\n",__FILE__,__LINE__);
        return -1;
    }

    if (touch_pages) {
        printf("[INFO] done alloc. Next, touch all pages\n");

        // alloc is only ready when accessed
        page_size = (unsigned long)getpagesize();
        page_cnt = (size / page_size);
        idx = 0;
        for (uint64_t i = 0; i < page_cnt; i++) {
            ptr[idx] = 0;
            idx += page_size;
        }
        printf("[INFO] done touching pages. Next, validate on node X\n");

        ret = get_node(ptr, size);
        if (ret != node) {
            printf("ptr is on node %d, but expect node %d\n", ret, node);
            return -2;
        }
        printf("ptr is on node %d\n", ret);

    } else {
        smart_log("Allocated mem, but pages are not touched\n");
    }

    printf("allocated: %luMB\n", (size >> 20));
    *alloc_ptr = ptr;

    return 0;
}


int node_free (char* ptr, uint64_t size) {
	numa_free(ptr, size);
	return 0;
}

int parse_arg(int argc, char** argv, cfg_t& cfg) {
    char opt;
    int ret = 0;
    bool has_epoch_cycle_a = false;
    bool has_epoch_cycle_b = false;

    while ((opt = getopt(argc, argv, "s:d:R:P:M:O:X:A:B:E:TLCprnSHh")) != -1) {
        switch (opt) {
            case 's':
                cfg.wait_ms = atoi(optarg);
                break;
            case 'R':
                cfg.is_traffic = true;
                cfg.is_traffic_rate = atoi(optarg);
                break;
            case 'P':
                cfg.target_pid = atoi(optarg);
                LOG_INFO("Target workload PID for PMU/cgroup metadata: %d\n", cfg.target_pid);
                break;
            case 'M':
                cfg.migration_interval_ms = atoi(optarg);
                LOG_INFO("Migration interval: %dms (0=use -s default)\n", cfg.migration_interval_ms);
                break;
            case 'O':
                cfg.pfn_offset = strtoull(optarg, NULL, 0);
                LOG_INFO("PFN offset: 0x%lx\n", cfg.pfn_offset);
                break;
            case 'X':
                cfg.max_migrated_pfns = strtoull(optarg, NULL, 0);
                if (cfg.max_migrated_pfns == 0) {
                    LOG_WARN("MAX_MIGRATED_PFNS cap disabled (unlimited). This may increase memory usage.\n");
                } else {
                    LOG_INFO("MAX_MIGRATED_PFNS cap: %lu\n", cfg.max_migrated_pfns);
                }
                break;
            case 'A':
                cfg.epoch_cycle_a = strtoull(optarg, NULL, 0);
                has_epoch_cycle_a = true;
                LOG_INFO("Mode0 epoch cycle: %lu\n", cfg.epoch_cycle_a);
                break;
            case 'B':
                cfg.epoch_cycle_b = strtoull(optarg, NULL, 0);
                has_epoch_cycle_b = true;
                LOG_INFO("Mode1 epoch cycle: %lu\n", cfg.epoch_cycle_b);
                break;
            case 'E':
                cfg.epoch_toggle_interval_ms = atoi(optarg);
                if (cfg.epoch_toggle_interval_ms <= 0) {
                    LOG_ERROR("Predictor interval must be > 0ms.\n");
                    ret = -1;
                } else {
                    LOG_INFO("Predictor interval: %dms\n", cfg.epoch_toggle_interval_ms);
                }
                break;
            case 'T':
                cfg.is_test = true;
                break;
            case 'L':
                cfg.print_list = true;
                break;
            case 'C':
                cfg.print_counter = true;
                break;
            case 'p':
                cfg.parsing_mode = true;
                cfg.print_counter = true;
                break;
            case 'r':
                cfg.is_traffic = true;
                break;
            case 'n':
                cfg.eac_migration = true;
                break;
            case 'd':
                cfg.do_dump = true;
                cfg.is_test = true;
                if (strlen(optarg) < MAX_PATH_LEN) {
                    strcpy(cfg.dump_path, optarg);
                    LOG_INFO("dump path: %s\n", cfg.dump_path);
                } else {
                    LOG_ERROR("file path <%s> is too long, please limit to %d characters\n", optarg, MAX_PATH_LEN);
                    ret = -1;
                }
                break;
            case 'S':
                cfg.separate_dump = true;
                cfg.print_list = true;
                break;
            case 'H':
                cfg.hw_reset = true;
                break;
            case 'h':
                printf("Usage: sudo ./migration_manager [options]\n");
                printf("  Kernel module migration: reads CHMU queue, writes PFN to /proc/cxl_migrate_pfn\n\n");
                printf(
                        " ----------------------------- with arg -----\n"
                        "   -P  target workload PID (for PMU/cgroup metadata)\n"
                        "   -M  migration interval in ms (0=use -s poll interval) [default = 0]\n"
                        "   -O  CHMU PFN to system PFN offset, hex ok [default = 0x2080000]\n"
                        "   -X  MAX_MIGRATED_PFNS cap for dedup entries (0=unlimited) [default = 250000]\n"
                        "   -A  mode0 CHMU epoch value\n"
                        "   -B  mode1 CHMU epoch value\n"
                        "   -E  ML predictor / perf sampling interval in ms [default = 100]\n"
                        "   -s  polling interval in ms [default = 10, matches CHMU epoch]\n"
                        "   -d  PAC dump path [default = no dumping]\n"
                        "   -R  traffic mode with custom rate [see csr.h for default]\n"
                        " ----------------------------- w/o arg -----\n"
                        "   -T  test mode: write to file instead of /proc [default = false]\n"
                        "   -L  print migration list [default = false]\n"
                        "   -C  print counter values [default = false]\n"
                        "   -p  parsing mode (implies -C) [default = false]\n"
                        "   -r  use traffic based query [default = clk based]\n"
                        "   -n  PAC+CHMU migration mode, use with -d [default = false]\n"
                        "   -S  separate dump: print CHMU and PAC PFNs separately\n"
                        "   -H  hardware reset PAC OFW buffer\n"
                        "   -h  print this message\n"
                );
                return -1;
            default:
                LOG_ERROR("Unknown arg %c\n", opt);
                ret = -1;
                break;
        }
        if (ret < 0) break;
    }

    if (ret == 0 && has_epoch_cycle_a != has_epoch_cycle_b) {
        LOG_ERROR("Both -A and -B must be provided together to enable runtime mode switching.\n");
        ret = -1;
    }

    if (ret == 0 && has_epoch_cycle_a && has_epoch_cycle_b) {
        if (cfg.epoch_cycle_a > 0xFFFFFFFFULL ||
            cfg.epoch_cycle_b > 0xFFFFFFFFULL) {
            LOG_ERROR("Epoch values must fit the 32-bit CHMU CSR.\n");
            return -1;
        }
        if (cfg.epoch_cycle_a == cfg.epoch_cycle_b) {
            LOG_WARN("Runtime mode switching disabled because -A and -B are identical (%lu).\n",
                     cfg.epoch_cycle_a);
            cfg.enable_epoch_toggle = false;
        } else {
            cfg.enable_epoch_toggle = true;
            LOG_INFO("Runtime mode switching enabled: mode0=%lu mode1=%lu (predictor interval=%dms)\n",
                     cfg.epoch_cycle_a, cfg.epoch_cycle_b, cfg.epoch_toggle_interval_ms);
        }
    }

    return ret;
}

void print_unordered_map_labeled(unordered_map<uint64_t, uint64_t>& map, const char* label) {
    cout << "=== " << label << " PFNs (" << map.size() << " entries) ===" << endl;
    int i = 0;
    for (const auto& pair : map) {
        if (i % 8 == 0) cout << i << " ";
        cout << "{" << std::hex << pair.first << ":" <<  std::dec << pair.second << "}   ";
        if (i % 8 == 7) cout << endl;
        i++;
        if (i == 256) break;
    }
    cout << endl;
}

#ifndef UTIL_H
#define UTIL_H

#include <stdint.h>
#include <stdbool.h>

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
#include <cstdint>
#include <iomanip>
#include <unordered_map>

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
using std::unordered_map;
using namespace std::chrono;

#define DEBUG 0

/* text color */
#define RED   "\x1B[31m"
#define GRN   "\x1B[32m"
#define YEL   "\x1B[33m"
#define BLU   "\x1B[34m"
#define MAG   "\x1B[35m"
#define CYN   "\x1B[36m"
#define WHT   "\x1B[37m"
#define RESET "\x1B[0m"

#define MAX_PATH_LEN    256

#define LOG_INFO(...) ( printf(GRN "[INFO] " RESET), printf(__VA_ARGS__))
#define LOG_WARN(...) ( printf(YEL "[WARN] " RESET), printf(__VA_ARGS__) )
#if DEBUG == 1
#define LOG_DEBUG(...) ( printf(MAG "[DEBUG] " RESET), printf(__VA_ARGS__) )
#else
#define LOG_DEBUG(...)
#endif // DEBUG
#define LOG_ERROR(...) ( printf(RED "[ERROR] " RESET), printf(__VA_ARGS__) )

#define debug_print(fmt, ...) \
        do { if (DEBUG) fprintf(stderr, "%s:%d:%s(): " fmt, __FILE__, \
                                __LINE__, __func__, __VA_ARGS__); } while (0)
#define smart_log(...) ( printf(CYN "[%s]: " RESET, __func__ ) , printf(__VA_ARGS__) )

#define DEBUG_LOG(x) do { \
      if (DEBUG) { std::cerr << x << std::endl; } \
} while (0)

#define IF_FAIL_THEN_EXIT       if (ret != 0) return -1;


typedef struct cfg {
    int wait_ms;
    bool is_test;
    bool print_counter;
    bool print_list;
    bool is_traffic;
    int is_traffic_rate;
    bool parsing_mode;
    bool do_dump;
    char dump_path[MAX_PATH_LEN];
    bool eac_migration;
    bool hw_reset;       // -H flag: hardware reset PAC OFW buffer
    bool separate_dump;  // -S flag: dump CHMU and PAC separately
    pid_t target_pid;    // -P flag: workload PID used to infer PMU/cgroup metadata
    int migration_interval_ms;  // -M flag: migration interval in ms (0 = use -s default)
    uint64_t pfn_offset;         // -O flag: CHMU PFN to system PFN offset (default 0x2080000)
    uint64_t max_migrated_pfns;   // -X flag: cap for dedup table entries (0 = unlimited) [default = 250000]
    bool enable_epoch_toggle;     // true when both -A and -B are provided
    uint64_t epoch_cycle_a;       // -A flag: first epoch value
    uint64_t epoch_cycle_b;       // -B flag: second epoch value
    int epoch_toggle_interval_ms; // -E flag: epoch toggle interval in ms [default = 100]
} cfg_t;


int get_node(void* p, uint64_t size);

int node_alloc(uint64_t size, int node, char** alloc_ptr, bool touch_pages);

int node_free (char* ptr, uint64_t size);

int parse_arg(int argc, char** argv, cfg_t& cfg);

void print_arr(uint64_t* arr, int len);

void print_arr_hex(uint64_t* arr, int len);

void print_unordered_map(unordered_map<uint64_t, uint64_t>& map);
void print_unordered_map_labeled(unordered_map<uint64_t, uint64_t>& map, const char* label);

void print_map(unordered_map<uint64_t, uint64_t>& map);

extern std::vector<u_int64_t> cycle_count_collector;

#endif

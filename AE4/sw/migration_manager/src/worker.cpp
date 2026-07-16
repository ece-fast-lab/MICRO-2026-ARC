#include "worker.h"
#include "util.h"
#include "csr.h"
#include <iostream>
#include <cstdio>
#include <sstream>
#include <cstring>
#include <cerrno>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <fstream>
#include <x86intrin.h>
#include <numa.h>
#include <new>
#include <type_traits>
#include <cstdlib>
#include <cstdint>
#include <utility>
#include <algorithm>
#include <cmath>
#include <map>
#include <deque>
#include <string>
#include <vector>
#include <cctype>
#include <glob.h>
#include <sys/wait.h>
#include <limits.h>

// NUMA-aware allocator: allocate from a specific NUMA node (best-effort).
// This keeps the dedup table on Node1 to reduce local(Node0) memory usage.
template <typename T, int NodeId>
struct NumaAllocator {
    using value_type = T;

    NumaAllocator() noexcept {}
    template <class U> NumaAllocator(const NumaAllocator<U, NodeId>&) noexcept {}

    struct alignas(16) Header {
        uint32_t magic;
        uint32_t used_numa;
        std::size_t total_bytes;
        std::size_t reserved;
    };

    static constexpr uint32_t kMagic = 0x4E554D41; // 'NUMA'

    T* allocate(std::size_t n) {
        if (n == 0) return nullptr;

        const std::size_t payload = n * sizeof(T);
        const std::size_t total = sizeof(Header) + payload;

        static int numa_ok = -2;
        if (numa_ok == -2) numa_ok = (numa_available() >= 0) ? 1 : 0;

        bool used_numa = false;
        void* raw = nullptr;
        if (numa_ok) {
            raw = numa_alloc_onnode(total, NodeId);
            if (raw) used_numa = true;
        }
        if (!raw) {
            raw = std::malloc(total);
            used_numa = false;
        }
        if (!raw) throw std::bad_alloc();

        auto* h = reinterpret_cast<Header*>(raw);
        h->magic = kMagic;
        h->used_numa = used_numa ? 1u : 0u;
        h->total_bytes = total;
        h->reserved = 0;

        return reinterpret_cast<T*>(reinterpret_cast<char*>(raw) + sizeof(Header));
    }

    void deallocate(T* p, std::size_t /*n*/) noexcept {
        if (!p) return;
        void* raw = reinterpret_cast<void*>(reinterpret_cast<char*>(p) - sizeof(Header));
        auto* h = reinterpret_cast<Header*>(raw);
        if (h->magic != kMagic) {
            std::free(raw);
            return;
        }

        const std::size_t total = h->total_bytes;

        static int numa_ok = -2;
        if (numa_ok == -2) numa_ok = (numa_available() >= 0) ? 1 : 0;

        if (numa_ok && h->used_numa) {
            numa_free(raw, total);
        } else {
            std::free(raw);
        }
    }

    template <class U>
    struct rebind { using other = NumaAllocator<U, NodeId>; };

    using is_always_equal = std::false_type;
};

template <class T1, int N1, class T2, int N2>
bool operator==(const NumaAllocator<T1, N1>&, const NumaAllocator<T2, N2>&) noexcept {
    return N1 == N2;
}
template <class T1, int N1, class T2, int N2>
bool operator!=(const NumaAllocator<T1, N1>& a, const NumaAllocator<T2, N2>& b) noexcept {
    return !(a == b);
}

using migrated_pfns_map_t = std::unordered_map<uint64_t, bool, std::hash<uint64_t>, std::equal_to<uint64_t>,
    NumaAllocator<std::pair<const uint64_t, bool>, 1>>;
using duplicate_pfns_debug_map_t = std::unordered_map<uint64_t, uint64_t, std::hash<uint64_t>, std::equal_to<uint64_t>,
    NumaAllocator<std::pair<const uint64_t, uint64_t>, 1>>;

static const uint64_t kDuplicateDebugPollWindow = 10;
static const uint64_t kMode0DuplicateCountThreshold = 3;
static const char* kDefaultPerfBin = "/research/chihuns2/kernel/linux-6.5.5/tools/perf/perf";
static const unsigned int kDefaultPredictorIntervalMs = 100;
static const unsigned int kPerfSampleStaleFloorMs = 5000;
static const unsigned int kPerfCollectorKeepaliveSec = 86400;
static const double kPredictorAlpha = 0.45;
static std::atomic<bool> stop_flag(false);

static inline void write_epoch_cycle_mmio(uint64_t* base, uint64_t epoch_cycle);

typedef struct duplicate_window_stats {
    uint64_t total_duplicate_hits;
    uint64_t max_duplicate_count;
    size_t unique_duplicate_addr;
} duplicate_window_stats_t;

typedef struct perf_core_sample {
    double timestamp_sec;
    double instructions;
    double cycles;
    double cache_references;
    double cache_misses;
    double llc_load_misses;
    double llc_store_misses;
    double dtlb_load_misses;
    double dtlb_store_misses;
    double slots;
    double topdown_mem_bound;
    double topdown_be_bound;
    double topdown_fe_bound;
    double topdown_retiring;
    bool has_instructions;
    bool has_cycles;
    bool has_cache_references;
    bool has_cache_misses;
    bool has_llc_load_misses;
    bool has_llc_store_misses;
    bool has_dtlb_load_misses;
    bool has_dtlb_store_misses;
    bool has_slots;
    bool has_topdown_mem_bound;
    bool has_topdown_be_bound;
    bool has_topdown_fe_bound;
    bool has_topdown_retiring;
} perf_core_sample_t;

typedef struct perf_imc_sample {
    double timestamp_sec;
    double read_mib;
    double write_mib;
    bool has_read;
    bool has_write;
} perf_imc_sample_t;

typedef struct perf_collector_context {
    pid_t core_pid;
    pid_t imc_pid;
    pid_t core_pgid;
    pid_t imc_pgid;
    std::string core_csv_path;
    std::string imc_csv_path;
    std::string core_log_path;
    std::string imc_log_path;
    off_t core_offset;
    off_t imc_offset;
    perf_core_sample_t latest_core;
    perf_imc_sample_t latest_imc;
    double last_prediction_timestamp_sec;
    unsigned int sample_interval_ms;
    std::string benchmark_key;
    std::string benchmark_desc;
    std::string cgroup_name;
    bool core_enabled;
    bool imc_enabled;
    bool initialized;
} perf_collector_context_t;

typedef struct predictor_window_counters {
    uint64_t poll_count;
    uint64_t queue_len_sum;
    uint64_t queue_len_max;
    uint64_t seen_pfns;
    uint64_t new_pfns;
    uint64_t dedup_pfns;
    uint64_t sentinel_pfns;
} predictor_window_counters_t;

typedef struct predictor_feature_window {
    bool valid;
    double timestamp_sec;
    double dram_read_bw_mib;
    double dram_write_bw_mib;
    double dram_total_bw_mib;
    double read_write_ratio;
    double ipc;
    double mpki;
    double llc_mpki;
    double cache_miss_ratio_pct;
    double dtlb_mpki;
    double memory_bound_pct;
    double backend_bound_pct;
    double frontend_bound_pct;
    double retiring_pct;
    double delta_total_bw_mib;
    double delta_ipc;
    double delta_mpki;
    double delta_memory_bound_pct;
    double ewma_total_bw_mib;
    double ewma_ipc;
    double ewma_mpki;
    double ewma_memory_bound_pct;
    double queue_len_avg;
    double queue_len_max;
    double duplicate_hit_rate;
    double max_duplicate_count;
    double unique_duplicate_addr;
    double total_duplicate_hits;
    double observed_pfn_count;
} predictor_feature_window_t;

typedef enum predictor_feature_id {
    FEAT_BW_RATIO = 0,
    FEAT_IPC_RATIO,
    FEAT_MPKI_RATIO,
    FEAT_LLC_MPKI_RATIO,
    FEAT_MEM_BOUND_RATIO,
    FEAT_QUEUE_RATIO,
    FEAT_DUP_RATIO,
    FEAT_MAX_DUP_RATIO,
    FEAT_DELTA_BW_RATIO,
    FEAT_DELTA_IPC_RATIO,
    FEAT_DELTA_MPKI_RATIO,
    FEAT_EWMA_BW_RATIO,
    FEAT_EWMA_MPKI_RATIO,
    FEAT_DTLB_RATIO,
    FEAT_COUNT
} predictor_feature_id_t;

typedef struct regression_tree_stump {
    predictor_feature_id_t feature_id;
    double threshold;
    double left_score;
    double right_score;
} regression_tree_stump_t;

typedef struct benchmark_model_config {
    const char* key;
    double bw_scale;
    double ipc_scale;
    double mpki_scale;
    double llc_mpki_scale;
    double mem_bound_scale;
    double queue_scale;
    double dup_rate_scale;
    double max_dup_scale;
    double dtlb_mpki_scale;
    double bias;
    double score_margin;
    int consecutive_votes_required;
    int consecutive_votes_required_weak;
} benchmark_model_config_t;

typedef struct predictor_state {
    bool enabled;
    bool fallback_to_duplicate_policy;
    bool allow_fallback;
    bool fatal_error;
    std::chrono::steady_clock::time_point last_perf_progress;
    predictor_window_counters_t window_counters;
    duplicate_pfns_debug_map_t predictor_duplicates;
    perf_collector_context_t perf;
    predictor_feature_window_t previous_window;
    bool has_previous_window;
    int pending_mode;
    int pending_votes;
    bool pending_vote_strong;
    benchmark_model_config_t model;
    std::string model_key;
    std::string model_source_path;
    FILE* feature_trace_fp;
} predictor_state_t;

static const regression_tree_stump_t kGenericSeedForest[] = {
    { FEAT_DUP_RATIO,         1.00, -0.30,  0.95 },
    { FEAT_MAX_DUP_RATIO,     1.00, -0.20,  0.85 },
    { FEAT_BW_RATIO,          1.00,  0.20, -0.80 },
    { FEAT_DELTA_BW_RATIO,    0.15,  0.15, -0.55 },
    { FEAT_MPKI_RATIO,        1.00,  0.10, -0.65 },
    { FEAT_LLC_MPKI_RATIO,    1.00,  0.10, -0.50 },
    { FEAT_MEM_BOUND_RATIO,   1.00,  0.10, -0.70 },
    { FEAT_IPC_RATIO,         1.00, -0.45,  0.25 },
    { FEAT_DELTA_IPC_RATIO,  -0.10, -0.45,  0.10 },
    { FEAT_QUEUE_RATIO,       1.00,  0.10, -0.35 },
    { FEAT_EWMA_BW_RATIO,     1.00,  0.10, -0.30 },
    { FEAT_EWMA_MPKI_RATIO,   1.00,  0.05, -0.30 },
    { FEAT_DTLB_RATIO,        1.00,  0.05, -0.20 },
};

static const benchmark_model_config_t kBenchmarkModels[] = {
    { "bc_twitter", 2500.0, 1.35, 2.60, 2.10, 32.0, 40.0, 0.14, 2.60, 0.90, -0.02, 0.16, 2, 3 },
    { "bc_web",     2800.0, 1.45, 2.90, 2.30, 34.0, 44.0, 0.16, 2.80, 1.00, -0.05, 0.18, 2, 3 },
    { "bc",   2600.0, 1.40, 2.80, 2.20, 32.0, 48.0, 0.16, 2.50, 1.00, -0.05, 0.18, 2, 3 },
    { "bfs",  2200.0, 1.60, 2.10, 1.60, 28.0, 32.0, 0.10, 2.00, 0.80,  0.10, 0.15, 2, 3 },
    { "cc",   1800.0, 1.50, 1.80, 1.50, 25.0, 24.0, 0.08, 2.00, 0.80,  0.15, 0.15, 2, 3 },
    { "pr",   3600.0, 1.00, 4.00, 3.50, 40.0, 80.0, 0.20, 3.50, 1.20, -0.10, 0.25, 2, 3 },
    { "502",  3200.0, 1.30, 3.00, 2.70, 35.0, 64.0, 0.18, 3.00, 1.00, -0.05, 0.20, 2, 3 },
    { "505",  1500.0, 1.70, 1.50, 1.20, 25.0, 28.0, 0.10, 2.00, 0.80,  0.05, 0.15, 2, 3 },
    { "507",  2300.0, 1.50, 2.00, 1.70, 30.0, 36.0, 0.11, 2.20, 0.90,  0.05, 0.17, 2, 3 },
    { "527",  2100.0, 1.40, 1.80, 1.50, 28.0, 36.0, 0.12, 2.20, 0.90,  0.00, 0.17, 2, 3 },
    { "554",  1700.0, 1.60, 1.30, 1.00, 24.0, 24.0, 0.10, 2.00, 0.80,  0.05, 0.15, 2, 3 },
    { "generic", 2800.0, 1.40, 2.50, 2.00, 30.0, 48.0, 0.14, 2.50, 1.00, 0.00, 0.20, 2, 3 },
};

static perf_core_sample_t make_empty_core_sample() {
    perf_core_sample_t sample;
    std::memset(&sample, 0, sizeof(sample));
    return sample;
}

static perf_imc_sample_t make_empty_imc_sample() {
    perf_imc_sample_t sample;
    std::memset(&sample, 0, sizeof(sample));
    return sample;
}

static predictor_feature_window_t make_empty_feature_window() {
    predictor_feature_window_t window;
    std::memset(&window, 0, sizeof(window));
    return window;
}

static predictor_window_counters_t make_empty_window_counters() {
    predictor_window_counters_t counters;
    std::memset(&counters, 0, sizeof(counters));
    return counters;
}

static std::string trim_copy(const std::string& input) {
    size_t begin = 0;
    while (begin < input.size() && std::isspace(static_cast<unsigned char>(input[begin])) != 0) {
        ++begin;
    }

    size_t end = input.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(input[end - 1])) != 0) {
        --end;
    }
    return input.substr(begin, end - begin);
}

static std::vector<std::string> split_csv_line(const std::string& line) {
    std::vector<std::string> fields;
    std::stringstream ss(line);
    std::string field;
    while (std::getline(ss, field, ',')) {
        fields.push_back(field);
    }
    return fields;
}

static bool parse_double_field(const std::string& field, double& out) {
    const std::string trimmed = trim_copy(field);
    if (trimmed.empty()) {
        return false;
    }

    char* end_ptr = NULL;
    const double value = std::strtod(trimmed.c_str(), &end_ptr);
    if (end_ptr == trimmed.c_str()) {
        return false;
    }

    out = value;
    return true;
}

static bool event_matches(const std::string& event_name,
                          const char* short_name,
                          const char* full_name) {
    return event_name == short_name || event_name == full_name;
}

static bool is_core_sample_usable(const perf_core_sample_t& sample) {
    return sample.has_instructions &&
           sample.has_cycles &&
           sample.has_cache_references &&
           sample.has_cache_misses &&
           sample.has_llc_load_misses &&
           sample.has_llc_store_misses &&
           sample.has_dtlb_load_misses &&
           sample.has_dtlb_store_misses;
}

static bool is_imc_sample_usable(const perf_imc_sample_t& sample) {
    return sample.has_read && sample.has_write;
}

static double clamp_non_negative(double value) {
    return (value < 0.0) ? 0.0 : value;
}

static duplicate_window_stats_t summarize_duplicate_pfns_window(const duplicate_pfns_debug_map_t& duplicate_pfns) {
    duplicate_window_stats_t stats = {0, 0, 0};
    for (duplicate_pfns_debug_map_t::const_iterator it = duplicate_pfns.begin();
         it != duplicate_pfns.end(); ++it) {
        stats.total_duplicate_hits += it->second;
        if (it->second > stats.max_duplicate_count) {
            stats.max_duplicate_count = it->second;
        }
    }
    stats.unique_duplicate_addr = duplicate_pfns.size();
    return stats;
}

static void apply_duplicate_mode_policy(uint64_t* pci_vaddr,
                                        bool mode_switch_enabled,
                                        uint64_t mode0_epoch_cycle,
                                        uint64_t mode1_epoch_cycle,
                                        const duplicate_window_stats_t& stats,
                                        uint64_t poll_begin,
                                        uint64_t poll_end,
                                        int& current_mode) {
    if (!mode_switch_enabled) {
        return;
    }

    const int target_mode = (stats.max_duplicate_count >= kMode0DuplicateCountThreshold) ? 0 : 1;
    const uint64_t target_epoch_cycle = (target_mode == 0) ? mode0_epoch_cycle : mode1_epoch_cycle;

    if (current_mode == target_mode) {
        return;
    }

    const int prev_mode = current_mode;
    const uint64_t prev_epoch_cycle = (prev_mode == 0) ? mode0_epoch_cycle :
                                      ((prev_mode == 1) ? mode1_epoch_cycle : 0);

    write_epoch_cycle_mmio(pci_vaddr, target_epoch_cycle);
    current_mode = target_mode;

    if (prev_mode >= 0) {
        LOG_INFO("[mode-switch] polls %lu-%lu: max_duplicate_count=%lu -> mode%d epoch=%lu (from mode%d epoch=%lu)\n",
                 poll_begin, poll_end, stats.max_duplicate_count,
                 target_mode, target_epoch_cycle, prev_mode, prev_epoch_cycle);
    } else {
        LOG_INFO("[mode-switch] polls %lu-%lu: max_duplicate_count=%lu -> mode%d epoch=%lu (initial apply)\n",
                 poll_begin, poll_end, stats.max_duplicate_count, target_mode, target_epoch_cycle);
    }
}

static void reset_predictor_window(predictor_state_t& predictor_state) {
    predictor_state.window_counters = make_empty_window_counters();
    predictor_state.predictor_duplicates.clear();
}

static std::string to_lower_copy(const std::string& input) {
    std::string lowered = input;
    std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return lowered;
}

static std::string shell_escape(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.size() + 8);
    escaped.push_back('\'');
    for (size_t i = 0; i < value.size(); ++i) {
        if (value[i] == '\'') {
            escaped.append("'\\''");
        } else {
            escaped.push_back(value[i]);
        }
    }
    escaped.push_back('\'');
    return escaped;
}

static bool read_file_to_string(const std::string& path, std::string& out, bool binary_mode) {
    std::ifstream input(path.c_str(), binary_mode ? (std::ios::in | std::ios::binary) : std::ios::in);
    if (!input.is_open()) {
        return false;
    }

    std::stringstream buffer;
    buffer << input.rdbuf();
    out = buffer.str();
    return true;
}

static std::string normalize_cmdline_text(const std::string& raw_cmdline) {
    std::string normalized = raw_cmdline;
    for (size_t i = 0; i < normalized.size(); ++i) {
        if (normalized[i] == '\0') {
            normalized[i] = ' ';
        }
    }
    return trim_copy(normalized);
}

static std::string infer_cgroup_name_from_pid(pid_t pid) {
    if (pid <= 0) {
        return "";
    }

    std::stringstream path_builder;
    path_builder << "/proc/" << pid << "/cgroup";

    std::ifstream input(path_builder.str().c_str());
    if (!input.is_open()) {
        return "";
    }

    std::string line;
    while (std::getline(input, line)) {
        const size_t last_colon = line.rfind(':');
        if (last_colon == std::string::npos || last_colon + 1 >= line.size()) {
            continue;
        }

        std::string cgroup_path = trim_copy(line.substr(last_colon + 1));
        if (cgroup_path.empty() || cgroup_path == "/") {
            continue;
        }

        while (!cgroup_path.empty() && cgroup_path[0] == '/') {
            cgroup_path.erase(cgroup_path.begin());
        }
        const size_t slash_pos = cgroup_path.find_last_of('/');
        if (slash_pos != std::string::npos && slash_pos + 1 < cgroup_path.size()) {
            return cgroup_path.substr(slash_pos + 1);
        }
        return cgroup_path;
    }

    return "";
}

static std::string infer_benchmark_key_from_pid(pid_t pid, std::string& benchmark_desc) {
    benchmark_desc.clear();
    if (pid <= 0) {
        return "generic";
    }

    std::stringstream cmdline_path;
    cmdline_path << "/proc/" << pid << "/cmdline";
    std::string cmdline_text;
    if (read_file_to_string(cmdline_path.str(), cmdline_text, true)) {
        benchmark_desc = normalize_cmdline_text(cmdline_text);
    }

    std::stringstream comm_path;
    comm_path << "/proc/" << pid << "/comm";
    std::string comm_text;
    if (read_file_to_string(comm_path.str(), comm_text, false)) {
        if (!benchmark_desc.empty()) {
            benchmark_desc.push_back(' ');
        }
        benchmark_desc.append(trim_copy(comm_text));
    }

    const std::string signature = to_lower_copy(benchmark_desc);
    const bool has_twitter = (signature.find("twitter") != std::string::npos);
    const bool has_web = (signature.find("web") != std::string::npos);
    if (signature.find("502") != std::string::npos) return "502";
    if (signature.find("505") != std::string::npos) return "505";
    if (signature.find("507") != std::string::npos) return "507";
    if (signature.find("527") != std::string::npos) return "527";
    if (signature.find("554") != std::string::npos) return "554";

    if (signature.find("/bc") != std::string::npos || signature.find(" bc ") != std::string::npos) {
        if (has_twitter) return "bc_twitter";
        if (has_web) return "bc_web";
        return "bc";
    }
    if (signature.find("/bfs") != std::string::npos || signature.find(" bfs ") != std::string::npos) {
        if (has_twitter) return "bfs_twitter";
        if (has_web) return "bfs_web";
        return "bfs";
    }
    if (signature.find("/cc") != std::string::npos || signature.find(" cc ") != std::string::npos) {
        if (has_twitter) return "cc_twitter";
        if (has_web) return "cc_web";
        return "cc";
    }
    if (signature.find("/pr") != std::string::npos || signature.find(" pr ") != std::string::npos) {
        if (has_twitter) return "pr_twitter";
        if (has_web) return "pr_web";
        return "pr";
    }

    return "generic";
}

static std::string benchmark_base_key(const std::string& benchmark_key) {
    const size_t underscore_pos = benchmark_key.find('_');
    if (underscore_pos == std::string::npos) {
        return benchmark_key;
    }
    return benchmark_key.substr(0, underscore_pos);
}

static benchmark_model_config_t resolve_benchmark_model(const std::string& benchmark_key) {
    for (size_t i = 0; i < sizeof(kBenchmarkModels) / sizeof(kBenchmarkModels[0]); ++i) {
        if (benchmark_key == kBenchmarkModels[i].key) {
            return kBenchmarkModels[i];
        }
    }

    const std::string base_key = benchmark_base_key(benchmark_key);
    if (base_key != benchmark_key) {
        for (size_t i = 0; i < sizeof(kBenchmarkModels) / sizeof(kBenchmarkModels[0]); ++i) {
            if (base_key == kBenchmarkModels[i].key) {
                return kBenchmarkModels[i];
            }
        }
    }

    return kBenchmarkModels[(sizeof(kBenchmarkModels) / sizeof(kBenchmarkModels[0])) - 1];
}

static void sanitize_model_config(benchmark_model_config_t& model) {
    model.consecutive_votes_required = std::max(1, model.consecutive_votes_required);
    model.consecutive_votes_required_weak = std::max(model.consecutive_votes_required + 1,
                                                     model.consecutive_votes_required_weak);
}

static bool parse_model_override_file(const std::string& path,
                                      benchmark_model_config_t& model,
                                      std::string& loaded_key) {
    std::ifstream input(path.c_str());
    if (!input.is_open()) {
        return false;
    }

    std::string line;
    while (std::getline(input, line)) {
        const std::string trimmed = trim_copy(line);
        if (trimmed.empty() || trimmed[0] == '#') {
            continue;
        }

        const size_t eq_pos = trimmed.find('=');
        if (eq_pos == std::string::npos) {
            continue;
        }

        const std::string key = trim_copy(trimmed.substr(0, eq_pos));
        const std::string value = trim_copy(trimmed.substr(eq_pos + 1));
        if (key.empty() || value.empty()) {
            continue;
        }

        char* end_ptr = NULL;
        if (key == "key") {
            loaded_key = value;
            continue;
        } else if (key == "consecutive_votes_required") {
            const long parsed = std::strtol(value.c_str(), &end_ptr, 10);
            if (end_ptr != value.c_str()) {
                model.consecutive_votes_required = std::max(1L, parsed);
            }
            continue;
        } else if (key == "consecutive_votes_required_weak") {
            const long parsed = std::strtol(value.c_str(), &end_ptr, 10);
            if (end_ptr != value.c_str()) {
                model.consecutive_votes_required_weak = std::max(0L, parsed);
            }
            continue;
        }

        const double parsed = std::strtod(value.c_str(), &end_ptr);
        if (end_ptr == value.c_str()) {
            continue;
        }

        if (key == "bw_scale") model.bw_scale = parsed;
        else if (key == "ipc_scale") model.ipc_scale = parsed;
        else if (key == "mpki_scale") model.mpki_scale = parsed;
        else if (key == "llc_mpki_scale") model.llc_mpki_scale = parsed;
        else if (key == "mem_bound_scale") model.mem_bound_scale = parsed;
        else if (key == "queue_scale") model.queue_scale = parsed;
        else if (key == "dup_rate_scale") model.dup_rate_scale = parsed;
        else if (key == "max_dup_scale") model.max_dup_scale = parsed;
        else if (key == "dtlb_mpki_scale") model.dtlb_mpki_scale = parsed;
        else if (key == "bias") model.bias = parsed;
        else if (key == "score_margin") model.score_margin = parsed;
    }

    return true;
}

static bool resolve_model_override_path(const std::string& benchmark_key, std::string& model_path) {
    model_path.clear();

    const char* env_path = std::getenv("CHMU_MODEL_PATH");
    if (env_path != NULL && env_path[0] != '\0') {
        if (access(env_path, R_OK) == 0) {
            model_path = env_path;
            return true;
        }
        LOG_WARN("[ml-predict] CHMU_MODEL_PATH is set but unreadable: %s\n", env_path);
    }

    std::vector<std::string> candidates;
    candidates.push_back("./ml_models/" + benchmark_key + ".cfg");
    candidates.push_back("./ml_models/" + benchmark_key + ".env");

    const std::string base_key = benchmark_base_key(benchmark_key);
    if (base_key != benchmark_key) {
        candidates.push_back("./ml_models/" + base_key + ".cfg");
        candidates.push_back("./ml_models/" + base_key + ".env");
    }

    for (size_t i = 0; i < candidates.size(); ++i) {
        if (access(candidates[i].c_str(), R_OK) == 0) {
            model_path = candidates[i];
            return true;
        }
    }
    return false;
}

static void resolve_predictor_model_config(const std::string& benchmark_key,
                                           predictor_state_t& predictor_state) {
    predictor_state.model_key = benchmark_key.empty() ? "generic" : benchmark_key;
    predictor_state.model = resolve_benchmark_model(predictor_state.model_key);
    sanitize_model_config(predictor_state.model);
    predictor_state.model_source_path = "builtin";

    std::string override_path;
    if (!resolve_model_override_path(predictor_state.model_key, override_path)) {
        return;
    }

    benchmark_model_config_t overridden_model = predictor_state.model;
    std::string loaded_key = predictor_state.model_key;
    if (!parse_model_override_file(override_path, overridden_model, loaded_key)) {
        LOG_WARN("[ml-predict] failed to parse model override: %s\n", override_path.c_str());
        return;
    }

    sanitize_model_config(overridden_model);
    predictor_state.model = overridden_model;
    predictor_state.model_source_path = override_path;
    if (!loaded_key.empty()) {
        predictor_state.model_key = loaded_key;
    }
    LOG_INFO("[ml-predict] loaded model override from %s\n", override_path.c_str());
}

static void close_feature_trace(predictor_state_t& predictor_state) {
    if (predictor_state.feature_trace_fp != NULL) {
        fclose(predictor_state.feature_trace_fp);
        predictor_state.feature_trace_fp = NULL;
    }
}

static void open_feature_trace_if_requested(predictor_state_t& predictor_state) {
    close_feature_trace(predictor_state);

    const char* trace_path = std::getenv("CHMU_FEATURE_TRACE_PATH");
    if (trace_path == NULL || trace_path[0] == '\0') {
        return;
    }

    predictor_state.feature_trace_fp = fopen(trace_path, "w");
    if (predictor_state.feature_trace_fp == NULL) {
        LOG_WARN("[ml-predict] failed to open feature trace path: %s\n", trace_path);
        return;
    }

    fprintf(predictor_state.feature_trace_fp,
            "timestamp_sec,model_key,model_source,score,voted_mode,strong_vote,mode_before,mode_after,switched,pending_mode,pending_votes,dram_read_bw_mib,dram_write_bw_mib,dram_total_bw_mib,ipc,mpki,llc_mpki,cache_miss_ratio_pct,dtlb_mpki,memory_bound_pct,backend_bound_pct,frontend_bound_pct,retiring_pct,delta_total_bw_mib,delta_ipc,delta_mpki,delta_memory_bound_pct,ewma_total_bw_mib,ewma_ipc,ewma_mpki,ewma_memory_bound_pct,queue_len_avg,queue_len_max,duplicate_hit_rate,max_duplicate_count,unique_duplicate_addr,total_duplicate_hits,observed_pfn_count\n");
    fflush(predictor_state.feature_trace_fp);
    LOG_INFO("[ml-predict] feature trace enabled: %s\n", trace_path);
}

static void write_feature_trace_row(FILE* trace_fp,
                                    const predictor_state_t& predictor_state,
                                    const predictor_feature_window_t& feature_window,
                                    double score,
                                    int voted_mode,
                                    bool strong_vote,
                                    int mode_before,
                                    int mode_after,
                                    bool switched) {
    if (trace_fp == NULL || !feature_window.valid) {
        return;
    }

    fprintf(trace_fp,
            "%.6f,%s,%s,%.6f,%d,%d,%d,%d,%d,%d,%d,"
            "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,"
            "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
            feature_window.timestamp_sec,
            predictor_state.model_key.c_str(),
            predictor_state.model_source_path.c_str(),
            score,
            voted_mode,
            strong_vote ? 1 : 0,
            mode_before,
            mode_after,
            switched ? 1 : 0,
            predictor_state.pending_mode,
            predictor_state.pending_votes,
            feature_window.dram_read_bw_mib,
            feature_window.dram_write_bw_mib,
            feature_window.dram_total_bw_mib,
            feature_window.ipc,
            feature_window.mpki,
            feature_window.llc_mpki,
            feature_window.cache_miss_ratio_pct,
            feature_window.dtlb_mpki,
            feature_window.memory_bound_pct,
            feature_window.backend_bound_pct,
            feature_window.frontend_bound_pct,
            feature_window.retiring_pct,
            feature_window.delta_total_bw_mib,
            feature_window.delta_ipc,
            feature_window.delta_mpki,
            feature_window.delta_memory_bound_pct,
            feature_window.ewma_total_bw_mib,
            feature_window.ewma_ipc,
            feature_window.ewma_mpki,
            feature_window.ewma_memory_bound_pct,
            feature_window.queue_len_avg,
            feature_window.queue_len_max,
            feature_window.duplicate_hit_rate,
            feature_window.max_duplicate_count,
            feature_window.unique_duplicate_addr,
            feature_window.total_duplicate_hits,
            feature_window.observed_pfn_count);
    fflush(trace_fp);
}

static std::string resolve_perf_binary_path() {
    const char* env_perf_bin = std::getenv("CHMU_PERF_BIN");
    if (env_perf_bin != NULL && env_perf_bin[0] != '\0') {
        return env_perf_bin;
    }
    return kDefaultPerfBin;
}

static bool process_is_running(pid_t pid) {
    if (pid <= 0) {
        return false;
    }

    int status = 0;
    const pid_t wait_result = waitpid(pid, &status, WNOHANG);
    if (wait_result == 0) {
        return kill(pid, 0) == 0;
    }
    if (wait_result == pid) {
        return false;
    }
    return false;
}

static pid_t spawn_background_command(const std::string& command,
                                      const std::string& log_path,
                                      pid_t& process_group) {
    process_group = -1;
    const pid_t child_pid = fork();
    if (child_pid < 0) {
        LOG_WARN("[ml-predict] fork failed for command: %s\n", command.c_str());
        return -1;
    }

    if (child_pid == 0) {
        if (setsid() < 0) {
            setpgid(0, 0);
        }

        const int log_fd = open(log_path.c_str(),
                                O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW);
        if (log_fd >= 0) {
            dup2(log_fd, STDOUT_FILENO);
            dup2(log_fd, STDERR_FILENO);
            close(log_fd);
        }

        execl("/bin/bash", "/bin/bash", "-lc", command.c_str(), (char*)NULL);
        _exit(127);
    }

    // The child creates a new session, or at minimum its own process group.
    // Retain this ID independently because waitpid() may reap the leader while
    // perf's workload child is still alive.
    process_group = child_pid;
    return child_pid;
}

static bool create_private_runtime_file(const std::string& path) {
    const int fd = open(path.c_str(),
                        O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                        0600);
    if (fd < 0) {
        LOG_WARN("[ml-predict] cannot securely create runtime file %s: %s\n",
                 path.c_str(), std::strerror(errno));
        return false;
    }
    if (close(fd) != 0) {
        unlink(path.c_str());
        return false;
    }
    return true;
}

static bool process_group_is_running(pid_t pgid) {
    if (pgid <= 0) {
        return false;
    }
    if (kill(-pgid, 0) == 0) {
        return true;
    }
    return errno == EPERM;
}

static void reap_background_leader(pid_t& pid) {
    if (pid <= 0) {
        return;
    }
    int status = 0;
    const pid_t wait_rc = waitpid(pid, &status, WNOHANG);
    if (wait_rc == pid || (wait_rc < 0 && errno == ECHILD)) {
        pid = -1;
    }
}

static void signal_background_process(pid_t pid, pid_t pgid, int signal_number) {
    if (pgid > 0) {
        kill(-pgid, signal_number);
    } else if (pid > 0) {
        kill(pid, signal_number);
    }
}

static bool wait_for_background_stop(pid_t& pid, pid_t pgid) {
    for (int i = 0; i < 20; ++i) {
        reap_background_leader(pid);
        if (!process_group_is_running(pgid) &&
            (pid <= 0 || !process_is_running(pid))) {
            return true;
        }
        usleep(10000);
    }
    return false;
}

static void stop_background_process(pid_t& pid, pid_t& pgid, const char* name) {
    if (pid <= 0 && pgid <= 0) {
        return;
    }

    const pid_t original_pid = pid;
    const pid_t target_pgid = pgid;

    signal_background_process(pid, target_pgid, SIGINT);
    if (!wait_for_background_stop(pid, target_pgid)) {
        signal_background_process(pid, target_pgid, SIGTERM);
    }
    if (!wait_for_background_stop(pid, target_pgid)) {
        signal_background_process(pid, target_pgid, SIGKILL);
    }

    if (pid > 0) {
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
    }
    LOG_INFO("[ml-predict] stopped %s collector pid=%d pgid=%d\n",
             name, original_pid, target_pgid);
    pid = -1;
    pgid = -1;
}

static bool read_new_lines_from_file(const std::string& path,
                                     off_t& file_offset,
                                     std::vector<std::string>& lines) {
    FILE* fp = fopen(path.c_str(), "r");
    if (fp == NULL) {
        return false;
    }

    if (file_offset > 0 && fseeko(fp, file_offset, SEEK_SET) != 0) {
        file_offset = 0;
        fseeko(fp, 0, SEEK_SET);
    }

    char buffer[2048];
    while (fgets(buffer, sizeof(buffer), fp) != NULL) {
        lines.push_back(buffer);
    }

    file_offset = ftello(fp);
    fclose(fp);
    return !lines.empty();
}

static bool parse_core_perf_csv_lines(const std::vector<std::string>& lines,
                                      perf_core_sample_t& latest_core) {
    std::map<double, perf_core_sample_t> parsed_samples;

    for (size_t i = 0; i < lines.size(); ++i) {
        const std::string line = trim_copy(lines[i]);
        if (line.empty() || line[0] == '#') {
            continue;
        }

        const std::vector<std::string> fields = split_csv_line(line);
        if (fields.size() < 4) {
            continue;
        }

        double timestamp_sec = 0.0;
        double value = 0.0;
        if (!parse_double_field(fields[0], timestamp_sec) || !parse_double_field(fields[1], value)) {
            continue;
        }

        perf_core_sample_t& sample = parsed_samples[timestamp_sec];
        if (sample.timestamp_sec == 0.0) {
            sample = make_empty_core_sample();
            sample.timestamp_sec = timestamp_sec;
        }

        const std::string event_name = trim_copy(fields[3]);
        if (event_matches(event_name, "instructions", "cpu/instructions/")) {
            sample.instructions = value;
            sample.has_instructions = true;
        } else if (event_matches(event_name, "cycles", "cpu/cpu-cycles/")) {
            sample.cycles = value;
            sample.has_cycles = true;
        } else if (event_matches(event_name, "cache-references", "cpu/cache-references/")) {
            sample.cache_references = value;
            sample.has_cache_references = true;
        } else if (event_matches(event_name, "cache-misses", "cpu/cache-misses/")) {
            sample.cache_misses = value;
            sample.has_cache_misses = true;
        } else if (event_matches(event_name, "LLC-load-misses", "cpu/LLC-load-misses/")) {
            sample.llc_load_misses = value;
            sample.has_llc_load_misses = true;
        } else if (event_matches(event_name, "LLC-store-misses", "cpu/LLC-store-misses/")) {
            sample.llc_store_misses = value;
            sample.has_llc_store_misses = true;
        } else if (event_matches(event_name, "dTLB-load-misses", "cpu/dTLB-load-misses/")) {
            sample.dtlb_load_misses = value;
            sample.has_dtlb_load_misses = true;
        } else if (event_matches(event_name, "dTLB-store-misses", "cpu/dTLB-store-misses/")) {
            sample.dtlb_store_misses = value;
            sample.has_dtlb_store_misses = true;
        } else if (event_matches(event_name, "slots", "cpu/slots/")) {
            sample.slots = value;
            sample.has_slots = true;
        } else if (event_matches(event_name, "topdown-mem-bound", "cpu/topdown-mem-bound/")) {
            sample.topdown_mem_bound = value;
            sample.has_topdown_mem_bound = true;
        } else if (event_matches(event_name, "topdown-be-bound", "cpu/topdown-be-bound/")) {
            sample.topdown_be_bound = value;
            sample.has_topdown_be_bound = true;
        } else if (event_matches(event_name, "topdown-fe-bound", "cpu/topdown-fe-bound/")) {
            sample.topdown_fe_bound = value;
            sample.has_topdown_fe_bound = true;
        } else if (event_matches(event_name, "topdown-retiring", "cpu/topdown-retiring/")) {
            sample.topdown_retiring = value;
            sample.has_topdown_retiring = true;
        }
    }

    for (std::map<double, perf_core_sample_t>::reverse_iterator it = parsed_samples.rbegin();
         it != parsed_samples.rend(); ++it) {
        if (it->first <= latest_core.timestamp_sec) {
            break;
        }
        if (is_core_sample_usable(it->second)) {
            latest_core = it->second;
            return true;
        }
    }

    return false;
}

static bool parse_imc_perf_csv_lines(const std::vector<std::string>& lines,
                                     perf_imc_sample_t& latest_imc) {
    std::map<double, perf_imc_sample_t> parsed_samples;

    for (size_t i = 0; i < lines.size(); ++i) {
        const std::string line = trim_copy(lines[i]);
        if (line.empty() || line[0] == '#') {
            continue;
        }

        const std::vector<std::string> fields = split_csv_line(line);
        if (fields.size() < 4) {
            continue;
        }

        double timestamp_sec = 0.0;
        double value = 0.0;
        if (!parse_double_field(fields[0], timestamp_sec) || !parse_double_field(fields[1], value)) {
            continue;
        }

        perf_imc_sample_t& sample = parsed_samples[timestamp_sec];
        if (sample.timestamp_sec == 0.0) {
            sample = make_empty_imc_sample();
            sample.timestamp_sec = timestamp_sec;
        }

        const std::string event_name = trim_copy(fields[3]);
        if (event_name.find("cas_count_read") != std::string::npos) {
            sample.read_mib += value;
            sample.has_read = true;
        } else if (event_name.find("cas_count_write") != std::string::npos) {
            sample.write_mib += value;
            sample.has_write = true;
        }
    }

    for (std::map<double, perf_imc_sample_t>::reverse_iterator it = parsed_samples.rbegin();
         it != parsed_samples.rend(); ++it) {
        if (it->first <= latest_imc.timestamp_sec) {
            break;
        }
        if (is_imc_sample_usable(it->second)) {
            latest_imc = it->second;
            return true;
        }
    }

    return false;
}

static bool resolve_imc_event_list(std::vector<std::string>& imc_events) {
    imc_events.clear();

    const char* patterns[] = {
        "/sys/bus/event_source/devices/uncore_imc_*/events/cas_count_read",
        "/sys/bus/event_source/devices/uncore_imc_*/events/cas_count_write",
    };

    for (size_t p = 0; p < sizeof(patterns) / sizeof(patterns[0]); ++p) {
        glob_t matches;
        std::memset(&matches, 0, sizeof(matches));
        if (glob(patterns[p], 0, NULL, &matches) != 0) {
            globfree(&matches);
            continue;
        }

        for (size_t i = 0; i < matches.gl_pathc; ++i) {
            const std::string path = matches.gl_pathv[i];
            const size_t dev_pos = path.find("/devices/");
            const size_t events_pos = path.find("/events/");
            if (dev_pos == std::string::npos || events_pos == std::string::npos || events_pos <= dev_pos + 9) {
                continue;
            }

            const std::string dev_name = path.substr(dev_pos + 9, events_pos - (dev_pos + 9));
            if (path.find("cas_count_read") != std::string::npos) {
                imc_events.push_back(dev_name + "/cas_count_read/");
            } else if (path.find("cas_count_write") != std::string::npos) {
                imc_events.push_back(dev_name + "/cas_count_write/");
            }
        }
        globfree(&matches);
    }

    std::sort(imc_events.begin(), imc_events.end());
    imc_events.erase(std::unique(imc_events.begin(), imc_events.end()), imc_events.end());
    return !imc_events.empty();
}

static void stop_perf_collectors(perf_collector_context_t& perf_ctx);
static bool refresh_perf_samples(perf_collector_context_t& perf_ctx);

static bool start_perf_collectors(pid_t target_pid,
                                  unsigned int predictor_interval_ms,
                                  perf_collector_context_t& perf_ctx) {
    if (stop_flag) {
        return false;
    }
    perf_ctx.core_pid = -1;
    perf_ctx.imc_pid = -1;
    perf_ctx.core_pgid = -1;
    perf_ctx.imc_pgid = -1;
    perf_ctx.core_offset = 0;
    perf_ctx.imc_offset = 0;
    perf_ctx.latest_core = make_empty_core_sample();
    perf_ctx.latest_imc = make_empty_imc_sample();
    perf_ctx.last_prediction_timestamp_sec = 0.0;
    perf_ctx.sample_interval_ms = predictor_interval_ms;
    perf_ctx.core_enabled = false;
    perf_ctx.imc_enabled = false;
    perf_ctx.initialized = false;

    perf_ctx.cgroup_name = infer_cgroup_name_from_pid(target_pid);
    perf_ctx.benchmark_key = infer_benchmark_key_from_pid(target_pid, perf_ctx.benchmark_desc);

    const std::string perf_bin = resolve_perf_binary_path();
    if (access(perf_bin.c_str(), X_OK) != 0) {
        LOG_WARN("[ml-predict] perf binary not executable: %s\n", perf_bin.c_str());
        return false;
    }

    const char* runtime_dir_env = std::getenv("CHMU_RUNTIME_DIR");
    char runtime_dir_resolved[PATH_MAX];
    struct stat runtime_dir_stat;
    if (runtime_dir_env == NULL || runtime_dir_env[0] != '/' ||
        realpath(runtime_dir_env, runtime_dir_resolved) == NULL ||
        stat(runtime_dir_resolved, &runtime_dir_stat) != 0 ||
        !S_ISDIR(runtime_dir_stat.st_mode) ||
        runtime_dir_stat.st_uid != 0 ||
        std::strncmp(runtime_dir_resolved, "/run/", 5) != 0 ||
        (runtime_dir_stat.st_mode & 0077) != 0) {
        LOG_WARN("[ml-predict] CHMU_RUNTIME_DIR must be an existing root-owned mode-0700 directory below /run.\n");
        return false;
    }
    const std::string runtime_dir(runtime_dir_resolved);

    if (perf_ctx.cgroup_name.empty()) {
        LOG_WARN("[ml-predict] failed to resolve workload cgroup from pid=%d; predictor disabled.\n",
                 target_pid);
        return false;
    }

    std::vector<std::string> imc_events;
    if (!resolve_imc_event_list(imc_events)) {
        LOG_WARN("[ml-predict] no IMC events found under /sys/bus/event_source/devices; predictor disabled.\n");
        return false;
    }

    const pid_t self_pid = getpid();
    std::stringstream suffix_builder;
    suffix_builder << self_pid << "_" << target_pid;
    const std::string suffix = suffix_builder.str();

    perf_ctx.core_csv_path = runtime_dir + "/chmu_ml_perf_core_" + suffix + ".csv";
    perf_ctx.imc_csv_path = runtime_dir + "/chmu_ml_perf_imc_" + suffix + ".csv";
    perf_ctx.core_log_path = runtime_dir + "/chmu_ml_perf_core_" + suffix + ".log";
    perf_ctx.imc_log_path = runtime_dir + "/chmu_ml_perf_imc_" + suffix + ".log";

    unlink(perf_ctx.core_csv_path.c_str());
    unlink(perf_ctx.imc_csv_path.c_str());
    unlink(perf_ctx.core_log_path.c_str());
    unlink(perf_ctx.imc_log_path.c_str());
    if (!create_private_runtime_file(perf_ctx.core_csv_path) ||
        !create_private_runtime_file(perf_ctx.imc_csv_path) ||
        !create_private_runtime_file(perf_ctx.core_log_path) ||
        !create_private_runtime_file(perf_ctx.imc_log_path)) {
        unlink(perf_ctx.core_csv_path.c_str());
        unlink(perf_ctx.imc_csv_path.c_str());
        unlink(perf_ctx.core_log_path.c_str());
        unlink(perf_ctx.imc_log_path.c_str());
        return false;
    }

    const char* core_events_with_topdown[] = {
        "instructions",
        "cycles",
        "cache-references",
        "cache-misses",
        "LLC-load-misses",
        "LLC-store-misses",
        "dTLB-load-misses",
        "dTLB-store-misses",
        "slots",
        "cpu/topdown-mem-bound/",
        "cpu/topdown-be-bound/",
        "cpu/topdown-fe-bound/",
        "cpu/topdown-retiring/",
    };
    const char* core_events_basic[] = {
        "instructions",
        "cycles",
        "cache-references",
        "cache-misses",
        "LLC-load-misses",
        "LLC-store-misses",
        "dTLB-load-misses",
        "dTLB-store-misses",
    };

    const auto build_core_command =
        [&](const char* const* events, size_t event_count) -> std::string {
            std::stringstream core_cmd;
            core_cmd << shell_escape(perf_bin)
                     << " stat -I " << predictor_interval_ms
                     << " -x, -o " << shell_escape(perf_ctx.core_csv_path)
                     << " -a";
            for (size_t i = 0; i < event_count; ++i) {
                core_cmd << " -e " << shell_escape(events[i]);
            }
            core_cmd << " -G " << shell_escape(perf_ctx.cgroup_name)
                     << " -- sleep " << kPerfCollectorKeepaliveSec;
            return core_cmd.str();
        };

    std::stringstream imc_cmd;
    imc_cmd << shell_escape(perf_bin)
            << " stat -I " << predictor_interval_ms
            << " -x, -o " << shell_escape(perf_ctx.imc_csv_path)
            << " -a";
    for (size_t i = 0; i < imc_events.size(); ++i) {
        imc_cmd << " -e " << shell_escape(imc_events[i]);
    }
    imc_cmd << " -- sleep " << kPerfCollectorKeepaliveSec;

    perf_ctx.core_pid = spawn_background_command(
        build_core_command(core_events_with_topdown,
                           sizeof(core_events_with_topdown) / sizeof(core_events_with_topdown[0])),
        perf_ctx.core_log_path,
        perf_ctx.core_pgid);
    usleep(200000);
    perf_ctx.core_enabled = process_is_running(perf_ctx.core_pid);
    if (!perf_ctx.core_enabled) {
        LOG_WARN("[ml-predict] failed to start core perf collector with topdown events. retrying without topdown. log=%s\n",
                 perf_ctx.core_log_path.c_str());
        stop_background_process(perf_ctx.core_pid, perf_ctx.core_pgid, "core perf retry");
        if (stop_flag) {
            return false;
        }
        perf_ctx.core_pid = spawn_background_command(
            build_core_command(core_events_basic,
                               sizeof(core_events_basic) / sizeof(core_events_basic[0])),
            perf_ctx.core_log_path,
            perf_ctx.core_pgid);
        usleep(200000);
        perf_ctx.core_enabled = process_is_running(perf_ctx.core_pid);
    }
    if (!perf_ctx.core_enabled) {
        LOG_WARN("[ml-predict] failed to start core perf collector. log=%s\n",
                 perf_ctx.core_log_path.c_str());
    }

    if (stop_flag) {
        stop_perf_collectors(perf_ctx);
        return false;
    }
    perf_ctx.imc_pid = spawn_background_command(
        imc_cmd.str(), perf_ctx.imc_log_path, perf_ctx.imc_pgid);
    usleep(200000);
    perf_ctx.imc_enabled = process_is_running(perf_ctx.imc_pid);
    if (!perf_ctx.imc_enabled) {
        LOG_WARN("[ml-predict] failed to start IMC perf collector. log=%s\n",
                 perf_ctx.imc_log_path.c_str());
    }

    perf_ctx.initialized = perf_ctx.core_enabled && perf_ctx.imc_enabled;
    if (!perf_ctx.initialized) {
        stop_perf_collectors(perf_ctx);
        return false;
    }

    bool initial_samples_ready = false;
    for (int attempt = 0; attempt < 50 && !stop_flag; ++attempt) {
        if (!process_is_running(perf_ctx.core_pid) ||
            !process_is_running(perf_ctx.imc_pid)) {
            break;
        }
        refresh_perf_samples(perf_ctx);
        if (is_core_sample_usable(perf_ctx.latest_core) &&
            is_imc_sample_usable(perf_ctx.latest_imc)) {
            initial_samples_ready = true;
            break;
        }
        usleep(100000);
    }
    if (!initial_samples_ready) {
        LOG_WARN("[ml-predict] perf collectors did not produce usable initial samples. core_log=%s imc_log=%s\n",
                 perf_ctx.core_log_path.c_str(), perf_ctx.imc_log_path.c_str());
        stop_perf_collectors(perf_ctx);
        return false;
    }

    LOG_INFO("[ml-predict] started perf collectors: benchmark=%s cgroup=%s interval=%ums\n",
             perf_ctx.benchmark_key.c_str(), perf_ctx.cgroup_name.c_str(), perf_ctx.sample_interval_ms);
    LOG_INFO("[ml-predict] workload signature: %s\n", perf_ctx.benchmark_desc.c_str());
    LOG_INFO("[ml-predict] core csv=%s imc csv=%s\n",
             perf_ctx.core_csv_path.c_str(), perf_ctx.imc_csv_path.c_str());
    return true;
}

static void stop_perf_collectors(perf_collector_context_t& perf_ctx) {
    stop_background_process(perf_ctx.core_pid, perf_ctx.core_pgid, "core perf");
    stop_background_process(perf_ctx.imc_pid, perf_ctx.imc_pgid, "imc perf");
    if (!perf_ctx.core_csv_path.empty()) unlink(perf_ctx.core_csv_path.c_str());
    if (!perf_ctx.imc_csv_path.empty()) unlink(perf_ctx.imc_csv_path.c_str());
    perf_ctx.core_enabled = false;
    perf_ctx.imc_enabled = false;
    perf_ctx.initialized = false;
}

static bool refresh_perf_samples(perf_collector_context_t& perf_ctx) {
    bool updated = false;

    std::vector<std::string> core_lines;
    if (perf_ctx.core_enabled &&
        read_new_lines_from_file(perf_ctx.core_csv_path, perf_ctx.core_offset, core_lines) &&
        parse_core_perf_csv_lines(core_lines, perf_ctx.latest_core)) {
        updated = true;
    }

    std::vector<std::string> imc_lines;
    if (perf_ctx.imc_enabled &&
        read_new_lines_from_file(perf_ctx.imc_csv_path, perf_ctx.imc_offset, imc_lines) &&
        parse_imc_perf_csv_lines(imc_lines, perf_ctx.latest_imc)) {
        updated = true;
    }

    return updated;
}

static double derive_memory_bound_pct(const perf_core_sample_t& sample,
                                      const predictor_feature_window_t& feature_window) {
    if (sample.has_slots && sample.slots > 0.0) {
        return clamp_non_negative((sample.topdown_mem_bound / sample.slots) * 100.0);
    }

    const double proxy = std::min(100.0,
                                  (feature_window.cache_miss_ratio_pct * 0.55) +
                                  (feature_window.llc_mpki * 12.0));
    return clamp_non_negative(proxy);
}

static predictor_feature_window_t build_feature_window(const perf_core_sample_t& core_sample,
                                                       const perf_imc_sample_t& imc_sample,
                                                       const predictor_window_counters_t& window_counters,
                                                       const duplicate_pfns_debug_map_t& predictor_duplicates,
                                                       const predictor_feature_window_t* previous_window) {
    predictor_feature_window_t feature_window = make_empty_feature_window();

    if (!is_core_sample_usable(core_sample) || !is_imc_sample_usable(imc_sample)) {
        return feature_window;
    }

    feature_window.valid = true;
    feature_window.timestamp_sec = std::min(core_sample.timestamp_sec, imc_sample.timestamp_sec);
    feature_window.dram_read_bw_mib = clamp_non_negative(imc_sample.read_mib);
    feature_window.dram_write_bw_mib = clamp_non_negative(imc_sample.write_mib);
    feature_window.dram_total_bw_mib = feature_window.dram_read_bw_mib + feature_window.dram_write_bw_mib;
    feature_window.read_write_ratio = feature_window.dram_read_bw_mib /
                                      std::max(1.0, feature_window.dram_write_bw_mib);

    feature_window.ipc = core_sample.instructions / std::max(1.0, core_sample.cycles);
    feature_window.mpki = (core_sample.cache_misses * 1000.0) / std::max(1.0, core_sample.instructions);
    feature_window.llc_mpki = ((core_sample.llc_load_misses + core_sample.llc_store_misses) * 1000.0) /
                              std::max(1.0, core_sample.instructions);
    feature_window.cache_miss_ratio_pct = (core_sample.cache_misses * 100.0) /
                                          std::max(1.0, core_sample.cache_references);
    feature_window.dtlb_mpki = ((core_sample.dtlb_load_misses + core_sample.dtlb_store_misses) * 1000.0) /
                               std::max(1.0, core_sample.instructions);

    duplicate_window_stats_t duplicate_stats = summarize_duplicate_pfns_window(predictor_duplicates);
    feature_window.total_duplicate_hits = static_cast<double>(duplicate_stats.total_duplicate_hits);
    feature_window.max_duplicate_count = static_cast<double>(duplicate_stats.max_duplicate_count);
    feature_window.unique_duplicate_addr = static_cast<double>(duplicate_stats.unique_duplicate_addr);
    feature_window.observed_pfn_count = static_cast<double>(window_counters.seen_pfns);
    feature_window.duplicate_hit_rate = feature_window.total_duplicate_hits /
                                        std::max(1.0, feature_window.observed_pfn_count);

    feature_window.queue_len_avg = static_cast<double>(window_counters.queue_len_sum) /
                                   std::max<uint64_t>(1, window_counters.poll_count);
    feature_window.queue_len_max = static_cast<double>(window_counters.queue_len_max);
    feature_window.memory_bound_pct = derive_memory_bound_pct(core_sample, feature_window);
    feature_window.backend_bound_pct = (core_sample.has_slots && core_sample.slots > 0.0)
        ? clamp_non_negative((core_sample.topdown_be_bound / core_sample.slots) * 100.0)
        : feature_window.memory_bound_pct;
    feature_window.frontend_bound_pct = (core_sample.has_slots && core_sample.slots > 0.0)
        ? clamp_non_negative((core_sample.topdown_fe_bound / core_sample.slots) * 100.0)
        : std::max(0.0, 100.0 - feature_window.backend_bound_pct);
    feature_window.retiring_pct = (core_sample.has_slots && core_sample.slots > 0.0)
        ? clamp_non_negative((core_sample.topdown_retiring / core_sample.slots) * 100.0)
        : std::max(0.0, 100.0 - feature_window.memory_bound_pct - feature_window.frontend_bound_pct);

    if (previous_window != NULL && previous_window->valid) {
        feature_window.delta_total_bw_mib = feature_window.dram_total_bw_mib - previous_window->dram_total_bw_mib;
        feature_window.delta_ipc = feature_window.ipc - previous_window->ipc;
        feature_window.delta_mpki = feature_window.mpki - previous_window->mpki;
        feature_window.delta_memory_bound_pct = feature_window.memory_bound_pct - previous_window->memory_bound_pct;

        feature_window.ewma_total_bw_mib =
            (kPredictorAlpha * feature_window.dram_total_bw_mib) +
            ((1.0 - kPredictorAlpha) * previous_window->ewma_total_bw_mib);
        feature_window.ewma_ipc =
            (kPredictorAlpha * feature_window.ipc) +
            ((1.0 - kPredictorAlpha) * previous_window->ewma_ipc);
        feature_window.ewma_mpki =
            (kPredictorAlpha * feature_window.mpki) +
            ((1.0 - kPredictorAlpha) * previous_window->ewma_mpki);
        feature_window.ewma_memory_bound_pct =
            (kPredictorAlpha * feature_window.memory_bound_pct) +
            ((1.0 - kPredictorAlpha) * previous_window->ewma_memory_bound_pct);
    } else {
        feature_window.delta_total_bw_mib = 0.0;
        feature_window.delta_ipc = 0.0;
        feature_window.delta_mpki = 0.0;
        feature_window.delta_memory_bound_pct = 0.0;
        feature_window.ewma_total_bw_mib = feature_window.dram_total_bw_mib;
        feature_window.ewma_ipc = feature_window.ipc;
        feature_window.ewma_mpki = feature_window.mpki;
        feature_window.ewma_memory_bound_pct = feature_window.memory_bound_pct;
    }

    return feature_window;
}

static double safe_ratio(double numerator, double denominator) {
    return numerator / std::max(1e-9, denominator);
}

static double evaluate_seed_forest_score(const benchmark_model_config_t& model,
                                         const predictor_feature_window_t& feature_window) {
    double normalized_features[FEAT_COUNT];
    std::memset(normalized_features, 0, sizeof(normalized_features));

    normalized_features[FEAT_BW_RATIO] = safe_ratio(feature_window.dram_total_bw_mib, model.bw_scale);
    normalized_features[FEAT_IPC_RATIO] = safe_ratio(feature_window.ipc, model.ipc_scale);
    normalized_features[FEAT_MPKI_RATIO] = safe_ratio(feature_window.mpki, model.mpki_scale);
    normalized_features[FEAT_LLC_MPKI_RATIO] = safe_ratio(feature_window.llc_mpki, model.llc_mpki_scale);
    normalized_features[FEAT_MEM_BOUND_RATIO] = safe_ratio(feature_window.memory_bound_pct, model.mem_bound_scale);
    normalized_features[FEAT_QUEUE_RATIO] = safe_ratio(feature_window.queue_len_avg, model.queue_scale);
    normalized_features[FEAT_DUP_RATIO] = safe_ratio(feature_window.duplicate_hit_rate, model.dup_rate_scale);
    normalized_features[FEAT_MAX_DUP_RATIO] = safe_ratio(feature_window.max_duplicate_count, model.max_dup_scale);
    normalized_features[FEAT_DELTA_BW_RATIO] = safe_ratio(feature_window.delta_total_bw_mib, model.bw_scale);
    normalized_features[FEAT_DELTA_IPC_RATIO] = safe_ratio(feature_window.delta_ipc, model.ipc_scale);
    normalized_features[FEAT_DELTA_MPKI_RATIO] = safe_ratio(feature_window.delta_mpki, model.mpki_scale);
    normalized_features[FEAT_EWMA_BW_RATIO] = safe_ratio(feature_window.ewma_total_bw_mib, model.bw_scale);
    normalized_features[FEAT_EWMA_MPKI_RATIO] = safe_ratio(feature_window.ewma_mpki, model.mpki_scale);
    normalized_features[FEAT_DTLB_RATIO] = safe_ratio(feature_window.dtlb_mpki, model.dtlb_mpki_scale);

    double score = model.bias;
    for (size_t i = 0; i < sizeof(kGenericSeedForest) / sizeof(kGenericSeedForest[0]); ++i) {
        const regression_tree_stump_t& tree = kGenericSeedForest[i];
        const double feature_value = normalized_features[tree.feature_id];
        score += (feature_value <= tree.threshold) ? tree.left_score : tree.right_score;
    }

    return score / static_cast<double>(sizeof(kGenericSeedForest) / sizeof(kGenericSeedForest[0]));
}

static void apply_ml_mode_policy(uint64_t* pci_vaddr,
                                 bool mode_switch_enabled,
                                 uint64_t mode0_epoch_cycle,
                                 uint64_t mode1_epoch_cycle,
                                 predictor_state_t& predictor_state,
                                 const predictor_feature_window_t& feature_window,
                                 int& current_mode) {
    if (!mode_switch_enabled || !feature_window.valid) {
        return;
    }

    const double score = evaluate_seed_forest_score(predictor_state.model, feature_window);
    const int voted_mode = (score >= 0.0) ? 0 : 1;
    const bool strong_vote = std::fabs(score) >= predictor_state.model.score_margin;
    const int mode_before = current_mode;

    LOG_INFO("[ml-feature] ts=%.3f model=%s bw(total/read/write)=%.2f/%.2f/%.2fMiB ipc=%.3f mpki=%.3f llc_mpki=%.3f mem_bound=%.2f queue_avg=%.2f dup_rate=%.3f max_dup=%.0f delta_bw=%.2f delta_ipc=%.3f delta_mpki=%.3f\n",
             feature_window.timestamp_sec,
             predictor_state.model_key.c_str(),
             feature_window.dram_total_bw_mib,
             feature_window.dram_read_bw_mib,
             feature_window.dram_write_bw_mib,
             feature_window.ipc,
             feature_window.mpki,
             feature_window.llc_mpki,
             feature_window.memory_bound_pct,
             feature_window.queue_len_avg,
             feature_window.duplicate_hit_rate,
             feature_window.max_duplicate_count,
             feature_window.delta_total_bw_mib,
             feature_window.delta_ipc,
             feature_window.delta_mpki);

    const int required_votes = strong_vote
        ? predictor_state.model.consecutive_votes_required
        : predictor_state.model.consecutive_votes_required_weak;

    if (voted_mode == current_mode) {
        predictor_state.pending_mode = -1;
        predictor_state.pending_votes = 0;
        predictor_state.pending_vote_strong = false;
        if (strong_vote) {
            LOG_INFO("[ml-predict] ts=%.3f model=%s score=%.3f -> stay mode%d\n",
                     feature_window.timestamp_sec,
                     predictor_state.model_key.c_str(),
                     score,
                     current_mode);
        } else {
            LOG_INFO("[ml-predict] ts=%.3f model=%s score=%.3f margin=%.3f -> stay mode%d (weak score)\n",
                     feature_window.timestamp_sec,
                     predictor_state.model_key.c_str(),
                     score,
                     predictor_state.model.score_margin,
                     current_mode);
        }
        write_feature_trace_row(predictor_state.feature_trace_fp,
                                predictor_state,
                                feature_window,
                                score,
                                voted_mode,
                                strong_vote,
                                mode_before,
                                current_mode,
                                false);
        return;
    }

    if (!strong_vote && required_votes <= 0) {
        predictor_state.pending_mode = -1;
        predictor_state.pending_votes = 0;
        predictor_state.pending_vote_strong = false;
        LOG_INFO("[ml-predict] ts=%.3f model=%s score=%.3f margin=%.3f -> hold mode%d (weak score, weak hysteresis disabled)\n",
                 feature_window.timestamp_sec,
                 predictor_state.model_key.c_str(),
                 score,
                 predictor_state.model.score_margin,
                 current_mode);
        write_feature_trace_row(predictor_state.feature_trace_fp,
                                predictor_state,
                                feature_window,
                                score,
                                voted_mode,
                                strong_vote,
                                mode_before,
                                current_mode,
                                false);
        return;
    }

    if (predictor_state.pending_mode == voted_mode &&
        predictor_state.pending_vote_strong == strong_vote) {
        predictor_state.pending_votes += 1;
    } else {
        predictor_state.pending_mode = voted_mode;
        predictor_state.pending_votes = 1;
        predictor_state.pending_vote_strong = strong_vote;
    }

    LOG_INFO("[ml-predict] ts=%.3f model=%s score=%.3f %s-vote=mode%d pending=%d/%d current_mode=%d\n",
             feature_window.timestamp_sec,
             predictor_state.model_key.c_str(),
             score,
             strong_vote ? "strong" : "weak",
             voted_mode,
             predictor_state.pending_votes,
             required_votes,
             current_mode);

    if (predictor_state.pending_votes < required_votes) {
        write_feature_trace_row(predictor_state.feature_trace_fp,
                                predictor_state,
                                feature_window,
                                score,
                                voted_mode,
                                strong_vote,
                                mode_before,
                                current_mode,
                                false);
        return;
    }

    const int prev_mode = current_mode;
    const uint64_t prev_epoch_cycle = (prev_mode == 0) ? mode0_epoch_cycle :
                                      ((prev_mode == 1) ? mode1_epoch_cycle : 0);
    const uint64_t target_epoch_cycle = (voted_mode == 0) ? mode0_epoch_cycle : mode1_epoch_cycle;

    write_epoch_cycle_mmio(pci_vaddr, target_epoch_cycle);
    current_mode = voted_mode;
    predictor_state.pending_mode = -1;
    predictor_state.pending_votes = 0;
    predictor_state.pending_vote_strong = false;

    LOG_INFO("[mode-switch][ml] ts=%.3f model=%s score=%.3f via=%s -> mode%d epoch=%lu (from mode%d epoch=%lu)\n",
             feature_window.timestamp_sec,
             predictor_state.model_key.c_str(),
             score,
             strong_vote ? "strong" : "weak",
             current_mode,
             target_epoch_cycle,
             prev_mode,
             prev_epoch_cycle);
    write_feature_trace_row(predictor_state.feature_trace_fp,
                            predictor_state,
                            feature_window,
                            score,
                            voted_mode,
                            strong_vote,
                            mode_before,
                            current_mode,
                            true);
}

static bool refresh_and_apply_ml_mode_policy(uint64_t* pci_vaddr,
                                             bool mode_switch_enabled,
                                             uint64_t mode0_epoch_cycle,
                                             uint64_t mode1_epoch_cycle,
                                             predictor_state_t& predictor_state,
                                             int& current_mode) {
    if (!mode_switch_enabled || !predictor_state.enabled) {
        return false;
    }

    refresh_perf_samples(predictor_state.perf);

    const double newest_ready_ts = std::min(predictor_state.perf.latest_core.timestamp_sec,
                                            predictor_state.perf.latest_imc.timestamp_sec);
    const bool core_alive = !predictor_state.perf.core_enabled ||
                            process_is_running(predictor_state.perf.core_pid);
    const bool imc_alive = !predictor_state.perf.imc_enabled ||
                           process_is_running(predictor_state.perf.imc_pid);

    const auto fail_or_fallback = [&](const char* reason) {
        LOG_WARN("[ml-predict] %s\n", reason);
        stop_perf_collectors(predictor_state.perf);
        predictor_state.enabled = false;
        predictor_state.pending_mode = -1;
        predictor_state.pending_votes = 0;
        predictor_state.pending_vote_strong = false;
        if (predictor_state.allow_fallback) {
            LOG_WARN("[ml-predict] CHMU_ALLOW_PREDICTOR_FALLBACK=1; switching to duplicate policy.\n");
            predictor_state.fallback_to_duplicate_policy = true;
        } else {
            LOG_ERROR("[ml-predict] PMU failure invalidates dynamic mode; stopping manager.\n");
            predictor_state.fallback_to_duplicate_policy = false;
            predictor_state.fatal_error = true;
        }
    };

    if ((!core_alive || !imc_alive) &&
        newest_ready_ts <= predictor_state.perf.last_prediction_timestamp_sec) {
        char reason[160];
        std::snprintf(reason, sizeof(reason),
                      "perf collector stopped (core_alive=%d, imc_alive=%d)",
                      core_alive ? 1 : 0, imc_alive ? 1 : 0);
        fail_or_fallback(reason);
        return false;
    }

    if (newest_ready_ts <= 0.0 ||
        newest_ready_ts <= predictor_state.perf.last_prediction_timestamp_sec) {
        const auto stale_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - predictor_state.last_perf_progress).count();
        const uint64_t stale_limit_ms = std::max<uint64_t>(
            kPerfSampleStaleFloorMs,
            static_cast<uint64_t>(predictor_state.perf.sample_interval_ms) * 10ULL);
        if (stale_ms >= static_cast<long long>(stale_limit_ms)) {
            char reason[192];
            std::snprintf(reason, sizeof(reason),
                          "paired core/IMC samples made no progress for %lldms (limit=%lums)",
                          static_cast<long long>(stale_ms),
                          static_cast<unsigned long>(stale_limit_ms));
            fail_or_fallback(reason);
        }
        return false;
    }
    predictor_feature_window_t feature_window = build_feature_window(
        predictor_state.perf.latest_core,
        predictor_state.perf.latest_imc,
        predictor_state.window_counters,
        predictor_state.predictor_duplicates,
        predictor_state.has_previous_window ? &predictor_state.previous_window : NULL);
    if (!feature_window.valid) {
        return false;
    }
    predictor_state.last_perf_progress = std::chrono::steady_clock::now();

    apply_ml_mode_policy(pci_vaddr,
                         mode_switch_enabled,
                         mode0_epoch_cycle,
                         mode1_epoch_cycle,
                         predictor_state,
                         feature_window,
                         current_mode);

    predictor_state.previous_window = feature_window;
    predictor_state.has_previous_window = true;
    predictor_state.perf.last_prediction_timestamp_sec = feature_window.timestamp_sec;
    reset_predictor_window(predictor_state);
    return true;
}

#define DUMMY_OUTPUT_TXT "/tmp/dummy_mig.txt"

// CHMU PFN to system PFN translation offset
// system_PFN = CHMU_PFN - pfn_offset  (subtraction, not addition!)
// CHMU internally adds 0x80000 to system PFN. Verified: -0x80000 gives 87.9% overlap.
// Default pfn_offset = 0x80000. Configurable via -O flag.

typedef struct pac_ofw_context {
    volatile uint64_t* pci_vaddr;
    uint64_t pac_ofw_buf_paddr;
    uint32_t* pac_ofw_buf_vaddr;
    uint32_t* cnt_table;

    // unit, 32 bits
    uint64_t prev_position = 0;
    uint64_t new_position = 0;
    uint64_t old_head = 0;

    // unit, 64 bytes
    uint64_t valid_cnt_diff = 0;
    volatile uint64_t prev_valid_cnt;

    uint64_t tmp_inc_cnt = 0;
    uint64_t all_zero_cnt = 0;
    uint64_t bad_diff_cnt = 0;
} pac_ofw_context_t;


// global variables
std::atomic<int> dump_cnt(0);
std::vector<thread> threads_vec;

std::vector<u_int64_t> cycle_count_collector;

uint64_t*   pci_vaddr_stop;

void stop_all() {
    stop_flag = true;
    for (size_t i = 0; i < cycle_count_collector.size(); i++) {
        LOG_INFO("Cycle count: %lu\n", cycle_count_collector[i]);
    }
}

int init_migration_ndoe(int node, bool is_test) {
    string proc_file_path = PATH_TO_MIGRATION_NODE;
    if (is_test) {
        proc_file_path = DUMMY_OUTPUT_TXT;
    }
    ofstream proc_file(proc_file_path);
    if (!proc_file.is_open()) {
        cerr << "Error: Unable to open node file: " << proc_file_path << endl;
        return 1;
    }
    proc_file << node;
    if (!proc_file.good()) {
        cerr << "Error: Failed to write to proc file " << proc_file_path << endl;
        proc_file.close();
        return 1;
    }
    proc_file.close();
    cout << "Data successfully written to proc file: " << proc_file_path << endl;
    return 0;
}

void check_path_exist(const char* dump_path) {
    struct stat st = {0};
    if (stat(dump_path, &st) == -1) {
        LOG_INFO("path {%s} does not exist, creating one ...\n", dump_path);
        mkdir(dump_path, 0777);
    } else {
        LOG_INFO("path {%s} exist!\n", dump_path);
    }
}

int worker_dump_func(char* dump_path) {
    cout << "Worker dumping thread is executing..." << endl;
    volatile int dump_cnt_local = 0;

    string file_path = string(dump_path);
    ofstream proc_file(file_path + "/offset_0/klog.txt");
    if (!proc_file.is_open()) {
        cerr << "[worker dump] Error: Unable to open [fist] dir " << (file_path + "/offset_0/klog.txt") << endl;
        return 1;
    } else {
        LOG_DEBUG("[worker dump] first dir ok\n");
    }
    while (!stop_flag) {
        if (dump_cnt_local != dump_cnt) {
            dump_cnt_local = dump_cnt;
            proc_file.close();

            std::ostringstream oss;
            oss.str("");
            oss << "/offset_" << (dump_cnt_local) << "/klog.txt";
            proc_file = ofstream(file_path + oss.str());
            cout << oss.str() << endl;
            if (!proc_file.is_open()) {
                cerr << "[worker dump] Error: Unable to [later] open proc file " << (file_path + oss.str()) << endl;
                return 1;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    LOG_INFO("Worker dump exit ok\n");
    cout << "stop flag = " << stop_flag << endl;
    proc_file.close();
    return 0;
}

int eac_func(char* dump_path, uint64_t* pci_vaddr, bool eac_migration) {
    int dump_cnt_local, ret;
    cout << "EAC dumping thread is executing..." << endl;
    string file_path = string(dump_path);
    while (!stop_flag) {
        dump_cnt_local = dump_cnt;
        LOG_INFO("eac iter: %d\n", (int)dump_cnt);
        // zero out
        start_zeroout(pci_vaddr);

        // sleep
        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        // dump
        string name = file_path + "/offset_" + std::to_string(dump_cnt_local) + "/counter_val_0.txt";
        dump_eac_buff(pci_vaddr, name.c_str());

        if (!eac_migration) {
            string cmd = "sudo dmesg -c > " + file_path + "/offset_" + std::to_string(dump_cnt_local) + "/klog.txt";
            ret = system(cmd.c_str());
            if (ret) {
                LOG_ERROR("eac_func dmesg dump failed \n");
            }
        }

        // mkdir
        dump_cnt_local += 1;
        name = file_path + "/offset_" + std::to_string(dump_cnt_local);
        check_path_exist(name.c_str());

        // inc
        dump_cnt += 1;
    }
    return 0;
}

void init_pac_ofw_ctx( pac_ofw_context_t& ctx,
        uint64_t* pci_vaddr,
        uint64_t pac_ofw_buf_paddr,
        uint32_t* pac_ofw_buf_vaddr,
        uint32_t* cnt_table) {

    ctx.pci_vaddr = pci_vaddr;
    ctx.pac_ofw_buf_paddr = pac_ofw_buf_paddr;
    ctx.pac_ofw_buf_vaddr = pac_ofw_buf_vaddr;
    ctx.cnt_table = cnt_table;

    // unit, 64 bytes
    ctx.valid_cnt_diff = 0;
    ctx.prev_valid_cnt = pci_vaddr[CSR_PAC_OFW_VALID_CNT];

    uint64_t init_valid_cnt = pci_vaddr[CSR_PAC_OFW_VALID_CNT];
    ctx.prev_position = (init_valid_cnt * (64 / sizeof(uint32_t))) % BUF_SIZE_BLOCK;
    ctx.new_position = ctx.prev_position;
    ctx.old_head = pci_vaddr[CSR_PAC_OFW_BUF_HEAD];

    ctx.tmp_inc_cnt = 0;
    ctx.all_zero_cnt = 0;
    ctx.bad_diff_cnt = 0;

    LOG_INFO("init_pac_ofw: HEAD=0x%lx, prev_position=%lu, prev_valid_cnt=%lu, init_vcnt=%lu\n",
             pci_vaddr[CSR_PAC_OFW_BUF_HEAD], ctx.prev_position, ctx.prev_valid_cnt, init_valid_cnt);
}

int dump_pac_ofw_buff(pac_ofw_context_t& ctx, const char* out_path) {
    FILE*       out_fd;
    int         non_zero_cnt = 0;
    int         val;

    if (out_path == NULL) {
        return -1;
    }
    out_fd = fopen(out_path, "w");
    if (out_fd == NULL) {
        LOG_ERROR("[ERROR] Can't open output file %s.\n", out_path);
        return -1;
    }

    for (uint32_t i = 0; i < CNT_TABLE_NUM_ENTRY; i++){
        val = ctx.cnt_table[i];
        if (val > 0) {
            non_zero_cnt++;
            fprintf(out_fd, "%x %x\n", i, val);
            ctx.cnt_table[i] = 0;
        }
    }
    fclose(out_fd);
    LOG_INFO("Dumping finished. Non-zero count: %d\n", non_zero_cnt);
    LOG_INFO("cnt tmp inc / bad diff / all zero: %lu, %lu, %lu\n",
            ctx.tmp_inc_cnt, ctx.bad_diff_cnt, ctx.all_zero_cnt);
    LOG_INFO("OK new valid / diff = %lu / %lu \n", ctx.prev_valid_cnt, ctx.valid_cnt_diff);
    return 0;
}

void accu_pac_ofw(pac_ofw_context_t& ctx) {

    uint64_t spin_cnt = 0;
    bool is_all_zero = true;
    uint32_t curr_dump_idx;
    std::chrono::microseconds sleep_us(10);

    while (ctx.pci_vaddr[CSR_PAC_OFW_VALID_CNT] == ctx.prev_valid_cnt) {
        std::this_thread::sleep_for(sleep_us);
        if (spin_cnt++ > 10000) {
            ctx.tmp_inc_cnt++;
            goto FAILED;
        }
        if (stop_flag) break;
    }

    // step 64 byte
    ctx.valid_cnt_diff = ctx.pci_vaddr[CSR_PAC_OFW_VALID_CNT] - ctx.prev_valid_cnt;
    ctx.prev_valid_cnt = ctx.pci_vaddr[CSR_PAC_OFW_VALID_CNT];
    if (ctx.valid_cnt_diff >= (BUF_SIZE_BYTE / 64)) {
        LOG_ERROR("BAD new valid / diff = %lu / %lu \n", ctx.prev_valid_cnt, ctx.valid_cnt_diff);
        uint64_t head_val = ctx.pci_vaddr[CSR_PAC_OFW_BUF_HEAD];
        uint64_t head_off = head_val - ctx.pac_ofw_buf_paddr;
        ctx.prev_position = (head_off / sizeof(uint32_t)) % BUF_SIZE_BLOCK;
        ctx.bad_diff_cnt++;
        goto FAILED;
    }

    // Use VALID_CNT to determine how many blocks were written.
    {
        uint64_t entries_to_read = ctx.valid_cnt_diff * (64 / sizeof(uint32_t));

        if (entries_to_read > BUF_SIZE_BLOCK / 2) {
            LOG_ERROR("Too many entries: vcnt_diff=%lu, entries=%lu\n",
                      ctx.valid_cnt_diff, entries_to_read);
            ctx.prev_position = (ctx.prev_position + entries_to_read) % BUF_SIZE_BLOCK;
            ctx.bad_diff_cnt++;
            goto FAILED;
        }

        // Flush CPU cache for the DMA buffer region we're about to read.
        for (uint64_t fi = 0; fi < entries_to_read; fi += (64 / sizeof(uint32_t))) {
            uint64_t buf_idx = (ctx.prev_position + fi) % BUF_SIZE_BLOCK;
            _mm_clflush(&ctx.pac_ofw_buf_vaddr[buf_idx]);
        }
        _mm_mfence();

        uint64_t sentinel_cnt = 0;
        for (uint64_t i = 0; i < entries_to_read; i++) {
            uint32_t raw_val = ctx.pac_ofw_buf_vaddr[(ctx.prev_position + i) % BUF_SIZE_BLOCK];
            if (raw_val == 0xFFFFFFFF) {
                sentinel_cnt++;
                continue;
            }
            curr_dump_idx = raw_val >> 6;
            if (curr_dump_idx < CNT_TABLE_NUM_ENTRY) {
                ctx.cnt_table[curr_dump_idx] += (1 << BITS_PER_SRAM_ENTRY);
            } else {
                LOG_ERROR("BAD index %u (raw=0x%08x)\n", curr_dump_idx, raw_val);
            }
            if (curr_dump_idx != 0) {
                is_all_zero = false;
            }
        }
        if (is_all_zero) {
            LOG_ERROR("all zero (%lu entries, %lu sentinel, prev=%lu, vcnt_diff=%lu)\n",
                      entries_to_read, sentinel_cnt, ctx.prev_position, ctx.valid_cnt_diff);
            for (uint64_t d = 0; d < 4 && d < entries_to_read; d++) {
                uint64_t idx = (ctx.prev_position + d) % BUF_SIZE_BLOCK;
                LOG_ERROR("  raw[%lu] = 0x%08x\n", idx, ctx.pac_ofw_buf_vaddr[idx]);
            }
            ctx.all_zero_cnt++;
        }

        uint64_t new_position = (ctx.prev_position + entries_to_read) % BUF_SIZE_BLOCK;
        ctx.old_head = ctx.pci_vaddr[CSR_PAC_OFW_BUF_HEAD];
        ctx.prev_position = new_position;
        ctx.new_position = new_position;
    }
    return;

FAILED:
    LOG_ERROR("end spin, %lu\n", spin_cnt);
    LOG_ERROR("BAD valid cnt, %lu\n", ctx.pci_vaddr[CSR_PAC_OFW_VALID_CNT]);
    LOG_ERROR("BAD old head? 0x%lx\n", ctx.old_head);
    LOG_ERROR("BAD new head? 0x%lx\n", ctx.pci_vaddr[CSR_PAC_OFW_BUF_HEAD]);
    LOG_ERROR("Exiting new valid / diff = %lu / %lu \n", ctx.prev_valid_cnt, ctx.valid_cnt_diff);
    LOG_ERROR("Exiting new / old = %lu / %lu, diff: %lu\n",
            ctx.new_position, ctx.prev_position, ctx.valid_cnt_diff);
    LOG_INFO("cnt tmp inc / bad diff / all zero: %lu, %lu, %lu\n",
            ctx.tmp_inc_cnt, ctx.bad_diff_cnt, ctx.all_zero_cnt);
}


int pac_ofw_func(char* dump_path,
        uint64_t* pci_vaddr,
        bool eac_migration,
        uint64_t pac_ofw_buf_paddr,
        uint32_t* pac_ofw_buf_vaddr) {

    int dump_cnt_local, ret;
    uint32_t* cnt_table;
    pac_ofw_context_t ctx;

    cout << "PAC OFW dumping thread is executing..." << endl;
    string file_path = string(dump_path);

    ret = node_alloc(CNT_TABLE_SIZE, 0, (char**)(&cnt_table), true);
    if (ret) {
        LOG_ERROR("Failed to alloc table\n");
        return -1;
    }

    init_pac_ofw_ctx(ctx, pci_vaddr, pac_ofw_buf_paddr, pac_ofw_buf_vaddr, cnt_table);

    while (!stop_flag) {
        dump_cnt_local = dump_cnt;
        LOG_INFO("eac iter: %d\n", (int)dump_cnt);

        // accumulate pac ofw to local table
        auto start = steady_clock::now();
        while (true) {
            auto now = steady_clock::now();
            auto elapsed = duration_cast<seconds>(now - start);

            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            accu_pac_ofw(ctx);

            if (elapsed.count() >= 1) { break; }
        }

        // dump & clear table
        string name = file_path + "/offset_" + std::to_string(dump_cnt_local) + "/counter_val_0.txt";
        ret = dump_pac_ofw_buff(ctx, name.c_str());

        if (ret) { LOG_ERROR("dump buff failed \n"); return -1;}

        if (!eac_migration) {
            string cmd = "sudo dmesg -c > " + file_path + "/offset_" + std::to_string(dump_cnt_local) + "/klog.txt";
            ret = system(cmd.c_str());
            if (ret) { LOG_ERROR("eac_func dmesg dump failed \n"); }
            else { LOG_INFO("dmesg dump ok\n"); }
        } else {
            LOG_INFO("no dmesg dump\n");
        }

        // mkdir for next dir
        dump_cnt_local += 1;
        name = file_path + "/offset_" + std::to_string(dump_cnt_local);
        check_path_exist(name.c_str());

        // inc
        dump_cnt += 1;
    }
    return 0;
}


void signal_handler(int signal) {
    if (signal == SIGINT || signal == SIGTERM) {
        stop_flag.store(true, std::memory_order_relaxed);
    }
}

static int publish_manager_ready() {
    const char* ready_path = std::getenv("CHMU_READY_FILE");
    if (ready_path == NULL || ready_path[0] == '\0') {
        return 0;
    }

    const int ready_fd = open(ready_path,
                              O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                              0644);
    if (ready_fd < 0) {
        LOG_ERROR("Unable to create manager readiness file %s: %s\n",
                  ready_path, std::strerror(errno));
        return -1;
    }

    char pid_text[32];
    const int pid_length = std::snprintf(pid_text, sizeof(pid_text), "%ld\n",
                                         static_cast<long>(getpid()));
    if (pid_length <= 0 || static_cast<size_t>(pid_length) >= sizeof(pid_text)) {
        close(ready_fd);
        unlink(ready_path);
        LOG_ERROR("Unable to format manager PID for readiness file %s\n",
                  ready_path);
        return -1;
    }
    const ssize_t written = write(ready_fd, pid_text,
                                  static_cast<size_t>(pid_length));
    const int close_result = close(ready_fd);
    if (written != pid_length || close_result != 0) {
        LOG_ERROR("Unable to publish manager PID in readiness file %s\n",
                  ready_path);
        unlink(ready_path);
        return -1;
    }
    return 0;
}

static void remove_manager_ready() {
    const char* ready_path = std::getenv("CHMU_READY_FILE");
    if (ready_path != NULL && ready_path[0] != '\0') {
        unlink(ready_path);
    }
    const char* start_path = std::getenv("CHMU_START_FILE");
    if (start_path != NULL && start_path[0] != '\0') {
        unlink(start_path);
    }
}

static int wait_for_manager_start() {
    const char* start_path = std::getenv("CHMU_START_FILE");
    if (start_path == NULL || start_path[0] == '\0') {
        return 0;
    }

    long timeout_sec = 30;
    const char* timeout_env = std::getenv("CHMU_START_GATE_TIMEOUT_SEC");
    if (timeout_env != NULL && timeout_env[0] != '\0') {
        char* end = NULL;
        errno = 0;
        const long parsed = std::strtol(timeout_env, &end, 10);
        if (errno != 0 || end == timeout_env || *end != '\0' || parsed <= 0) {
            LOG_ERROR("Invalid CHMU_START_GATE_TIMEOUT_SEC: %s\n", timeout_env);
            return -1;
        }
        timeout_sec = parsed;
    }

    for (long attempt = 0; attempt < timeout_sec * 10 && !stop_flag; ++attempt) {
        if (access(start_path, F_OK) == 0) {
            unlink(start_path);
            return 0;
        }
        usleep(100000);
    }
    LOG_ERROR("Timed out waiting for runner start gate: %s\n", start_path);
    return -1;
}


// =============================================================================
// MMIO helpers: volatile 64-bit access to PCIe BAR CSRs
// =============================================================================
static inline volatile uint64_t* mmio_ptr(uint64_t* base) {
    return reinterpret_cast<volatile uint64_t*>(base);
}

static inline void write_epoch_cycle_mmio(uint64_t* base, uint64_t epoch_cycle) {
    volatile uint32_t* epoch_register = reinterpret_cast<volatile uint32_t*>(
        reinterpret_cast<uint8_t*>(base) + (CSR_PFN_RATE * sizeof(uint64_t)));
    *epoch_register = static_cast<uint32_t>(epoch_cycle);
    (void)*epoch_register;
}

// =============================================================================
// Kernel module migration: read CHMU queue -> write PFNs to
// /proc/cxl_migrate_pfn for kernel module page migration.
//
// NO QUEUE RESET from C code — same approach as movepages version.
// Bash init script resets queue via pcimem before launching migration_manager.
// We read the queue incrementally without resetting, tracking already-migrated
// PFNs to skip duplicates.
//
// Process-agnostic: No PID needed. The kernel module migrates physical pages
// directly regardless of which process owns them.
// Optional -P <pid> identifies workload PMU/cgroup metadata. Workload lifetime
// is owned by the runner; this manager must not infer whole-workload completion
// from a single wrapper/orchestrator PID.
// =============================================================================
int run_kmod_migration(uint64_t* pci_vaddr, cfg_t& cfg) {
    // Keep CSR writes to a minimum in migration mode.
    // Runtime CSR writes are limited to mode switches selected by the predictor.

    // Init migration target node via /proc/cxl_migrate_node
    int ret = init_migration_ndoe(MIGRATION_TARGET_NODE, cfg.is_test);
    if (ret) {
        LOG_ERROR("Failed to set migration target node\n");
        return -1;
    }

    // Open migration proc file
    string proc_file_path = PATH_TO_MIGRATION_PFN;
    if (cfg.is_test) {
        proc_file_path = DUMMY_OUTPUT_TXT;
    }

    // Use FILE* for better flush control (ofstream may buffer too aggressively)
    FILE* proc_fp = fopen(proc_file_path.c_str(), "w");
    if (!proc_fp) {
        LOG_ERROR("Error: Unable to open proc file %s: %s\n",
                  proc_file_path.c_str(), strerror(errno));
        return -1;
    }

    int effective_poll_ms = (cfg.migration_interval_ms > 0) ? cfg.migration_interval_ms : cfg.wait_ms;
    const bool mode_switch_enabled = cfg.enable_epoch_toggle;
    const uint64_t mode0_epoch_cycle = cfg.epoch_cycle_a;
    const uint64_t mode1_epoch_cycle = cfg.epoch_cycle_b;
    const unsigned int predictor_interval_ms = (cfg.epoch_toggle_interval_ms > 0)
        ? static_cast<unsigned int>(cfg.epoch_toggle_interval_ms)
        : kDefaultPredictorIntervalMs;
    LOG_INFO("kmod migration started (writing system PFN to %s, poll=%dms, pfn_offset=-0x%lx)\n",
             proc_file_path.c_str(), effective_poll_ms, cfg.pfn_offset);

    uint64_t total_migrated = 0;
    uint64_t total_sentinel = 0;
    uint64_t total_dedup = 0;
    uint64_t total_new_pfn = 0;
    uint64_t cycle_count = 0;

    // Set of already-migrated system PFNs (so we skip them on re-reads)
    // The CHMU queue is a small FIFO (~32 entries) that wraps. We must read
    // ALL entries every cycle and deduplicate against our global set.
    migrated_pfns_map_t migrated_pfns;
    duplicate_pfns_debug_map_t duplicate_pfns_window;

    // Limit dedup table size to avoid unbounded memory growth (best-effort dedup)
    // Default is 250000; configurable via -X <cap> (0 = unlimited).
    const size_t MAX_MIGRATED_PFNS = (cfg.max_migrated_pfns > 0)
        ? static_cast<size_t>(cfg.max_migrated_pfns)
        : 0;
    uint64_t dedup_clears = 0;
    bool migration_failed = false;
    int current_mode = mode_switch_enabled ? 0 : -1;
    predictor_state_t predictor_state = predictor_state_t();
    predictor_state.allow_fallback =
        (std::getenv("CHMU_ALLOW_PREDICTOR_FALLBACK") != NULL &&
         std::strcmp(std::getenv("CHMU_ALLOW_PREDICTOR_FALLBACK"), "1") == 0);
    predictor_state.fatal_error = false;
    predictor_state.last_perf_progress = std::chrono::steady_clock::now();
    predictor_state.window_counters = make_empty_window_counters();
    predictor_state.previous_window = make_empty_feature_window();
    predictor_state.pending_mode = -1;
    predictor_state.pending_votes = 0;
    predictor_state.pending_vote_strong = false;
    predictor_state.model_key = "generic";
    predictor_state.model = resolve_benchmark_model(predictor_state.model_key);
    predictor_state.model_source_path = "builtin";
    predictor_state.feature_trace_fp = NULL;
    predictor_state.perf.core_pid = -1;
    predictor_state.perf.imc_pid = -1;
    predictor_state.perf.core_pgid = -1;
    predictor_state.perf.imc_pgid = -1;
    predictor_state.perf.latest_core = make_empty_core_sample();
    predictor_state.perf.latest_imc = make_empty_imc_sample();

    if (mode_switch_enabled) {
        if (cfg.target_pid > 0 &&
            start_perf_collectors(cfg.target_pid, predictor_interval_ms, predictor_state.perf)) {
            predictor_state.enabled = true;
            predictor_state.fallback_to_duplicate_policy = false;
            predictor_state.last_perf_progress = std::chrono::steady_clock::now();
            resolve_predictor_model_config(
                predictor_state.perf.benchmark_key.empty() ? "generic" : predictor_state.perf.benchmark_key,
                predictor_state);
            open_feature_trace_if_requested(predictor_state);
            LOG_INFO("[ml-predict] benchmark-specific seed forest enabled: model=%s interval=%ums margin=%.3f hysteresis=%d windows weak_hysteresis=%d windows\n",
                     predictor_state.model_key.c_str(),
                     predictor_interval_ms,
                     predictor_state.model.score_margin,
                     predictor_state.model.consecutive_votes_required,
                     predictor_state.model.consecutive_votes_required_weak);
            LOG_INFO("[ml-predict] model source: %s\n", predictor_state.model_source_path.c_str());
            LOG_INFO("[mode-switch] ML policy active: mode0(epoch=%lu) vs mode1(epoch=%lu)\n",
                     mode0_epoch_cycle, mode1_epoch_cycle);
        } else {
            predictor_state.enabled = false;
            if (!predictor_state.allow_fallback) {
                LOG_ERROR("[ml-predict] dynamic mode requires working core and IMC perf collectors.\n");
                LOG_ERROR("Set CHMU_ALLOW_PREDICTOR_FALLBACK=1 only for a non-reproduction debug run.\n");
                fclose(proc_fp);
                return -1;
            }
            predictor_state.fallback_to_duplicate_policy = true;
            LOG_WARN("[ml-predict] predictor unavailable; debug fallback to duplicate policy enabled.\n");
            LOG_INFO("[mode-switch] duplicate fallback enabled: max_duplicate_count >= %lu => mode0(epoch=%lu), otherwise mode1(epoch=%lu), window=%lu polls\n",
                     kMode0DuplicateCountThreshold, mode0_epoch_cycle, mode1_epoch_cycle, kDuplicateDebugPollWindow);
        }
    }

    if (publish_manager_ready() != 0) {
        stop_perf_collectors(predictor_state.perf);
        close_feature_trace(predictor_state);
        fclose(proc_fp);
        return -1;
    }
    if (wait_for_manager_start() != 0) {
        stop_perf_collectors(predictor_state.perf);
        close_feature_trace(predictor_state);
        fclose(proc_fp);
        remove_manager_ready();
        return -1;
    }

    const uint64_t predictor_refresh_stride = (mode_switch_enabled && predictor_state.enabled)
        ? std::max<uint64_t>(1,
                             (static_cast<uint64_t>(predictor_interval_ms) +
                              static_cast<uint64_t>(std::max(1, effective_poll_ms)) - 1) /
                             static_cast<uint64_t>(std::max(1, effective_poll_ms)))
        : 0;

    while (!stop_flag) {
        // Read CHMU queue length
        uint64_t raw_queue_csr = mmio_ptr(pci_vaddr)[CSR_QUEUE_LEN];
        uint64_t chmu_queue_len = (raw_queue_csr >> 32) & 0x3FF;

        // Clamp to reasonable max (hardware FIFO is ~32 entries)
        if (chmu_queue_len > 1023) chmu_queue_len = 1023;

        if (predictor_state.enabled) {
            predictor_state.window_counters.poll_count += 1;
            predictor_state.window_counters.queue_len_sum += chmu_queue_len;
            predictor_state.window_counters.queue_len_max =
                std::max<uint64_t>(predictor_state.window_counters.queue_len_max, chmu_queue_len);
        }

        if (chmu_queue_len > 0) {
            uint64_t batch_migrated = 0;
            uint64_t batch_dedup = 0;
            uint64_t batch_sentinel = 0;
            uint64_t batch_new = 0;

            // Read ALL queue entries every cycle. The FIFO wraps, so
            // we can't rely on queue_len growing monotonically.
            for (uint64_t i = 0; i < chmu_queue_len; i++) {
                uint64_t current_pfn = (mmio_ptr(pci_vaddr)[CSR_PFN_QUEUE_OFFSET + i] & 0xFFFFFFFF);

                if (current_pfn == 0x021FFFFF) { batch_sentinel++; continue; }
                if (current_pfn == 0) continue;

                //uint64_t system_pfn = current_pfn - cfg.pfn_offset;
                uint64_t system_pfn = current_pfn;// - cfg.pfn_offset;

                // Skip already-migrated PFNs
                if (migrated_pfns.count(system_pfn)) {
                    batch_dedup++;
                    if (predictor_state.enabled) {
                        predictor_state.predictor_duplicates[system_pfn] += 1;
                    } else if (predictor_state.fallback_to_duplicate_policy) {
                        duplicate_pfns_window[system_pfn] += 1;
                    }
                    continue;
                }

                // New PFN — migrate it
                batch_new++;

                // Write system PFN to /proc/cxl_migrate_pfn
                // Kernel module converts PFN to PA internally (pfn <<= PAGE_SHIFT)
                if (fprintf(proc_fp, "%lx\n", system_pfn) < 0 ||
                    fflush(proc_fp) != 0) {
                    LOG_ERROR("Failed to write PFN 0x%lx to %s: %s\n",
                              system_pfn, proc_file_path.c_str(), strerror(errno));
                    migration_failed = true;
                    break;
                }

                // if (cfg.print_list) {
                //     LOG_INFO("  MIGRATE PFN: 0x%lx (CHMU: 0x%lx)\n",
                //              system_pfn, current_pfn);
                // }

                migrated_pfns[system_pfn] = true;
                // Prevent dedup table from growing without bound
                if (MAX_MIGRATED_PFNS > 0 && migrated_pfns.size() >= MAX_MIGRATED_PFNS) {
                    migrated_pfns.clear();
                    dedup_clears++;
                    LOG_WARN("[dedup] migrated_pfns reached cap (%zu). cleared (count=%lu).\n",
                             MAX_MIGRATED_PFNS, dedup_clears);
                }
                batch_migrated++;
            }

            if (migration_failed) {
                break;
            }

            // Reset queue after reading so CHMU can push fresh entries next cycle
            // (Same pattern as original ASPLOS migration_manager_uspace)
            mmio_ptr(pci_vaddr)[CSR_PFN_QUEUE_RESET] = 1;

            total_migrated += batch_migrated;
            total_sentinel += batch_sentinel;
            total_dedup += batch_dedup;
            total_new_pfn += batch_new;

            if (predictor_state.enabled) {
                predictor_state.window_counters.seen_pfns += (batch_new + batch_dedup);
                predictor_state.window_counters.new_pfns += batch_new;
                predictor_state.window_counters.dedup_pfns += batch_dedup;
                predictor_state.window_counters.sentinel_pfns += batch_sentinel;
            }

            // if (batch_new > 0 || (cycle_count % 10 == 0)) {
            //     LOG_INFO("Cycle %lu: qlen=%lu, new=%lu, dedup=%lu, sentinel=%lu (total migrated: %lu unique PFNs)\n",
            //              cycle_count, chmu_queue_len, batch_new, batch_dedup, batch_sentinel, total_migrated);
            // }

            // Print FPGA counters if requested
            if (batch_new > 0 && cfg.print_counter) {
                static fpga_counters_t counter_record = {0};
                static bool counter_initialized = false;
                fpga_counters_t counter_curr;

                uint64_t raw_clk = mmio_ptr(pci_vaddr)[CSR_CLOCK];
                uint64_t raw_rd  = mmio_ptr(pci_vaddr)[CSR_READ_CNT];
                uint64_t raw_wr  = mmio_ptr(pci_vaddr)[CSR_WRITE_CNT];
                uint64_t raw_pfn = mmio_ptr(pci_vaddr)[CSR_PFN_CNT] & 0xFFFFFFFF;
                uint64_t raw_push = mmio_ptr(pci_vaddr)[CSR_PUSH_CNT];

                if (!counter_initialized) {
                    // First read: store baseline, show zeros for delta
                    counter_record.clock = raw_clk;
                    counter_record.read = raw_rd;
                    counter_record.write = raw_wr;
                    counter_record.pfn_cnt = raw_pfn;
                    counter_record.push_cnt = raw_push;
                    counter_initialized = true;
                }

                counter_curr.queue_len = chmu_queue_len;
                counter_curr.clock = raw_clk - counter_record.clock;
                counter_curr.read = raw_rd - counter_record.read;
                counter_curr.write = raw_wr - counter_record.write;
                counter_curr.pfn_cnt = raw_pfn - counter_record.pfn_cnt;
                counter_curr.push_cnt = raw_push - counter_record.push_cnt;

                if (counter_curr.clock > 0) {
                    counter_curr.rd_bw = (counter_curr.read * 64 * CSR_MHZ) / (counter_curr.clock * 1024 * 1024);
                    counter_curr.wr_bw = (counter_curr.write * 64 * CSR_MHZ) / (counter_curr.clock * 1024 * 1024);
                } else {
                    counter_curr.rd_bw = 0;
                    counter_curr.wr_bw = 0;
                }

                // Update record for next delta
                counter_record.clock = raw_clk;
                counter_record.read = raw_rd;
                counter_record.write = raw_wr;
                counter_record.pfn_cnt = raw_pfn;
                counter_record.push_cnt = raw_push;

                print_counters(pci_vaddr, counter_curr, cfg.parsing_mode);
            }
        }

        cycle_count++;

        if (predictor_state.fallback_to_duplicate_policy &&
            (cycle_count % kDuplicateDebugPollWindow) == 0) {
            const uint64_t poll_begin = cycle_count - kDuplicateDebugPollWindow + 1;
            duplicate_window_stats_t stats = summarize_duplicate_pfns_window(duplicate_pfns_window);
            apply_duplicate_mode_policy(pci_vaddr,
                                        mode_switch_enabled,
                                        mode0_epoch_cycle,
                                        mode1_epoch_cycle,
                                        stats,
                                        poll_begin,
                                        cycle_count,
                                        current_mode);
            duplicate_pfns_window.clear();
        }

        if (predictor_state.enabled &&
            predictor_refresh_stride > 0 &&
            (cycle_count % predictor_refresh_stride) == 0) {
            refresh_and_apply_ml_mode_policy(pci_vaddr,
                                             mode_switch_enabled,
                                             mode0_epoch_cycle,
                                             mode1_epoch_cycle,
                                             predictor_state,
                                             current_mode);
            if (predictor_state.fatal_error) {
                migration_failed = true;
                break;
            }
        }

        // Poll interval — use -M if set, otherwise -s (default 200ms)
        for (int w = 0; w < (effective_poll_ms) && !stop_flag; w++) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }

    if (predictor_state.enabled) {
        refresh_and_apply_ml_mode_policy(pci_vaddr,
                                         mode_switch_enabled,
                                         mode0_epoch_cycle,
                                         mode1_epoch_cycle,
                                         predictor_state,
                                         current_mode);
        if (predictor_state.fatal_error) {
            migration_failed = true;
        }
    }

    if (predictor_state.fallback_to_duplicate_policy &&
        ((cycle_count % kDuplicateDebugPollWindow) != 0 || !duplicate_pfns_window.empty())) {
        uint64_t poll_begin = 1;
        if (cycle_count > 0) {
            poll_begin = cycle_count - (cycle_count % kDuplicateDebugPollWindow) + 1;
        }
        duplicate_window_stats_t stats = summarize_duplicate_pfns_window(duplicate_pfns_window);
        apply_duplicate_mode_policy(pci_vaddr,
                                    mode_switch_enabled,
                                    mode0_epoch_cycle,
                                    mode1_epoch_cycle,
                                    stats,
                                    poll_begin,
                                    cycle_count,
                                    current_mode);
        duplicate_pfns_window.clear();
    }

    stop_perf_collectors(predictor_state.perf);
    close_feature_trace(predictor_state);
    fclose(proc_fp);
    remove_manager_ready();
    // LOG_INFO("kmod migration stopped. Total migrated: %lu, dedup: %lu, sentinel: %lu, unique new: %lu\n",
    //          total_migrated, total_dedup, total_sentinel, total_new_pfn);
    return migration_failed ? -1 : 0;
}


// =============================================================================
// Thread management
// =============================================================================
void join_threads() {
    for (uint64_t i = 0; i < threads_vec.size(); ++i) {
        cout << "thread joining for " << i << endl;
        threads_vec[i].join();
        cout << "thread joining for [ok] " << i << endl;
    }
    cout << "All threads have [ended]" << endl;
}

int start_threads(uint64_t* pci_vaddr, cfg_t cfg,
        uint64_t pac_ofw_buf_paddr, uint32_t* pac_ofw_buf_vaddr) {

    int ret = 0;

    // Register termination handlers so child perf collectors are stopped.
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    if (cfg.do_dump) {
        // PAC dump mode
        std::ostringstream oss;
        oss << "/offset_" << 0;
        string proc_file_path = string(cfg.dump_path);
        check_path_exist(cfg.dump_path);
        check_path_exist(proc_file_path.append(oss.str()).c_str());

        threads_vec.emplace_back(pac_ofw_func,
                cfg.dump_path, pci_vaddr, cfg.eac_migration,
                pac_ofw_buf_paddr,
                pac_ofw_buf_vaddr);

        if (cfg.eac_migration) {
            threads_vec.emplace_back(worker_dump_func, cfg.dump_path);
        }

        // Block on Ctrl-C
        while (!stop_flag) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    } else if (cfg.separate_dump) {
        // Separate dump mode: print CHMU and PAC PFNs separately
        unordered_map<uint64_t, uint64_t> chmu_pfn;
        unordered_map<uint64_t, uint64_t> pac_pfn;
        fpga_counters_t counter_curr;

        set_default_counters(pci_vaddr, cfg.is_traffic);

        while (!stop_flag) {
            chmu_pfn.clear();
            pac_pfn.clear();

            fetch_migrate_list_separate(counter_curr, pci_vaddr, chmu_pfn, pac_pfn,
                                        cfg.wait_ms, 0, MIGRATE_LIST_MAX_LEN,
                                        pac_ofw_buf_vaddr, pac_ofw_buf_paddr);
            print_unordered_map_labeled(chmu_pfn, "CHMU");
            print_unordered_map_labeled(pac_pfn, "PAC");

            if (cfg.print_counter) {
                print_counters(pci_vaddr, counter_curr, cfg.parsing_mode);
            }

            std::this_thread::sleep_for(std::chrono::milliseconds(cfg.wait_ms));
        }
    } else {
        // Kernel module migration mode
        ret = run_kmod_migration(pci_vaddr, cfg);
        if (ret) {
            LOG_ERROR("run_kmod_migration failed\n");
        }
    }

    // Join any background threads (PAC dump threads)
    join_threads();
    LOG_DEBUG("all threads joined, exiting ...");
    return ret;
}

module chmu_tracker #(
  parameter ADDR_SIZE      = 21,
  parameter INDEX_SIZE     = 10,
  parameter NUM_WAY        = 4,
  parameter TAG_SIZE       = ADDR_SIZE - INDEX_SIZE,
  parameter CNT_SIZE       = 12,
  parameter HOT_TH         = 10,  // Default hot threshold (now configurable via CSR[25])
  parameter LIST_SIZE      = 32,
  parameter SAMPLING_RATE  = 1
)(
  input  logic                          clk,
  input  logic                          rst_n,

  input  logic [ADDR_SIZE-1:0]          input_addr,
  input  logic                          input_addr_valid,
  output logic                          output_addr_ready,

  input  logic                          query_en,
  input  logic                          counter_mode,
  output logic                          query_ready,

  output logic                          mig_addr_cnt_en,
  output logic [ADDR_SIZE+CNT_SIZE-1:0] mig_addr_cnt,
  input  logic                          mig_addr_cnt_ready,

  input  logic [11:0]                   hot_threshold,  // Dynamic hot threshold from CSR[25]

  // ===== DEBUG OUTPUTS =====
  output logic [63:0]                   debug_tracker_status,    // Tracker state and signals
  output logic [63:0]                   debug_sampling_status,   // Sampling module status
  output logic [63:0]                   debug_counter_set_status,// Counter set internal status
  output logic [63:0]                   debug_hotlist_internal   // Hotlist internal status
);

  // wiring between stages
  logic [ADDR_SIZE-1:0]  sampling_output_addr;
  logic                  sampling_output_addr_valid;

  logic [ADDR_SIZE-1:0]  counter_hot_addr;
  logic [CNT_SIZE-1:0]   counter_hot_cnt;
  logic                  counter_hot_valid;
  logic [ADDR_SIZE-1:0]  lfu_hot_addr;
  logic [CNT_SIZE-1:0]   lfu_hot_cnt;
  logic                  lfu_hot_valid;
  logic [ADDR_SIZE-1:0]  cm_hot_addr;
  logic [CNT_SIZE-1:0]   cm_hot_cnt;
  logic                  cm_hot_valid;

  logic [1:0]                  state, next_state;
  localparam STATE_IDLE  				= 2'd0;
  localparam STATE_REQ_1  			= 2'd1;
  localparam STATE_REQ_2        = 2'd2;
  localparam STATE_EPOCH        = 2'd3;

  // state transition
  always_comb begin
    next_state = STATE_IDLE;
    case(state)
      STATE_IDLE: begin
        if (query_en) begin
          next_state = STATE_EPOCH;
        end
        else if (input_addr_valid) begin
          next_state = STATE_REQ_1;
        end
      end
      STATE_REQ_1: begin
        if (query_en) begin
          next_state = STATE_EPOCH;
        end
        else begin
          next_state = STATE_REQ_2;
        end
      end
      STATE_REQ_2: begin 
        if (query_en) begin
          next_state = STATE_EPOCH;
        end
        else if (input_addr_valid) begin
          next_state = STATE_REQ_1;
        end        
      end   
      STATE_EPOCH: begin 
        if (query_en) begin
          next_state = STATE_EPOCH;
        end
        else if (input_addr_valid) begin
          next_state = STATE_REQ_1;
        end
      end
      default:;
    endcase 
  end

  assign output_addr_ready = (state == STATE_IDLE) | (state == STATE_REQ_2);

  always_ff @ (posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= 2'b0;
    end
    else begin
      state <= next_state;
    end
  end

  sampling_module #(
    .ADDR_SIZE     (ADDR_SIZE),
    .SAMPLING_RATE (SAMPLING_RATE)
  ) 
  u_sampling_module (
    .clk               (clk),
    .rst_n             (rst_n),

    .input_addr        (input_addr),
    .input_addr_valid  (input_addr_valid),
    .epoch             (query_en),
    
    .output_addr       (sampling_output_addr),
    .output_addr_valid (sampling_output_addr_valid)
  );

  lfu_3cycle_counter_set #(
    .ADDR_SIZE (ADDR_SIZE),
    .INDEX_SIZE(INDEX_SIZE),
    .NUM_WAY   (NUM_WAY),
    .TAG_SIZE  (TAG_SIZE),
    .CNT_SIZE  (CNT_SIZE),
    .HOT_TH    (HOT_TH)
  )
  u_lfu_counter_set (
    .clk               (clk),
    .rst_n             (rst_n),

    .input_addr        (sampling_output_addr),
    .input_addr_valid  (sampling_output_addr_valid),
    .epoch             (query_en),

    .hot_threshold     (hot_threshold),

    .output_addr       (lfu_hot_addr),
    .output_cnt        (lfu_hot_cnt),
    .output_valid      (lfu_hot_valid)
  );

  cm_sketch_counter #(
    .ADDR_SIZE (ADDR_SIZE),
    .INDEX_SIZE(INDEX_SIZE),
    .NUM_WAY   (NUM_WAY),
    .TAG_SIZE  (TAG_SIZE),
    .CNT_SIZE  (CNT_SIZE),
    .HOT_TH    (HOT_TH)
  )
  u_cm_sketch_counter (
    .clk               (clk),
    .rst_n             (rst_n),

    .input_addr        (sampling_output_addr),
    .input_addr_valid  (sampling_output_addr_valid),
    .epoch             (query_en),

    .hot_threshold     (hot_threshold),  // Dynamic hot threshold from CSR[25]

    .output_addr       (cm_hot_addr),
    .output_cnt        (cm_hot_cnt),
    .output_valid      (cm_hot_valid)
  );

  assign counter_hot_addr  = counter_mode ? cm_hot_addr  : lfu_hot_addr;
  assign counter_hot_cnt   = counter_mode ? cm_hot_cnt   : lfu_hot_cnt;
  assign counter_hot_valid = counter_mode ? cm_hot_valid : lfu_hot_valid;

  // Debug signals from counter_set
  logic [63:0] counter_set_debug;

  // Debug signals from hotlist
  logic [63:0] hotlist_debug;

  hotlist #(
    .ADDR_SIZE (ADDR_SIZE),
    .CNT_SIZE  (CNT_SIZE),
    .LIST_SIZE (LIST_SIZE)
  )
  u_hotlist (
    .clk                    (clk),
    .rst_n                  (rst_n),

    .input_addr             (counter_hot_addr),
    .input_cnt              (counter_hot_cnt),
    .input_valid            (counter_hot_valid),

    .query_en               (query_en),
    .query_ready            (query_ready),

    // NOTE: Port directions swapped to match hotlist interface:
    // - hotlist.mig_addr_cnt_ready (OUTPUT) provides valid signal → tracker.mig_addr_cnt_en (OUTPUT)
    // - hotlist.mig_addr_cnt_en (INPUT) receives ack signal ← tracker.mig_addr_cnt_ready (INPUT)
    .mig_addr_cnt_en        (mig_addr_cnt_ready),   // Hotlist ack INPUT ← tracker ready INPUT
    .mig_addr_cnt           (mig_addr_cnt),
    .mig_addr_cnt_ready     (mig_addr_cnt_en),      // Hotlist valid OUTPUT → tracker enable OUTPUT

    // Debug output
    .debug_status           (hotlist_debug)
  );

  // ============================================================================
  // DEBUG: Comprehensive counters for every stage
  // ============================================================================

  // Counter: Input valid pulses received by tracker
  logic [31:0] tracker_input_valid_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      tracker_input_valid_cnt <= 32'h0;
    else if (input_addr_valid)
      tracker_input_valid_cnt <= tracker_input_valid_cnt + 1;
  end

  // Counter: Sampling module output valid pulses
  logic [31:0] sampling_output_valid_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      sampling_output_valid_cnt <= 32'h0;
    else if (sampling_output_addr_valid)
      sampling_output_valid_cnt <= sampling_output_valid_cnt + 1;
  end

  // Counter: Counter_set hot page outputs
  logic [31:0] counter_hot_valid_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      counter_hot_valid_cnt <= 32'h0;
    else if (counter_hot_valid)
      counter_hot_valid_cnt <= counter_hot_valid_cnt + 1;
  end

  // Counter: Migration outputs from hotlist
  logic [31:0] mig_output_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      mig_output_cnt <= 32'h0;
    else if (mig_addr_cnt_en & mig_addr_cnt_ready)
      mig_output_cnt <= mig_output_cnt + 1;
  end

  // Counter: Query enable pulses
  logic [31:0] query_en_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      query_en_cnt <= 32'h0;
    else if (query_en)
      query_en_cnt <= query_en_cnt + 1;
  end

  // Capture last valid input address for debugging
  logic [20:0] last_input_addr;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      last_input_addr <= 21'h0;
    else if (input_addr_valid)
      last_input_addr <= input_addr[20:0];
  end

  // ===== Debug Status Outputs =====

  // debug_tracker_status: Overall tracker state
  assign debug_tracker_status = {
    tracker_input_valid_cnt[15:0],  // [63:48] Input valid count
    sampling_output_valid_cnt[15:0],// [47:32] Sampling output count
    counter_hot_valid_cnt[15:0],    // [31:16] Hot page detection count
    mig_output_cnt[7:0],            // [15:8]  Migration output count
    query_en_cnt[3:0],              // [7:4]   Query enable count
    output_addr_ready,              // [3]     Ready signal
    query_ready,                    // [2]     Query ready
    state[1:0]                      // [1:0]   State machine
  };

  // debug_sampling_status: Sampling module signals
  assign debug_sampling_status = {
    last_input_addr[20:0],          // [63:43] Last input address
    11'h0,                          // [42:32] Reserved
    sampling_output_addr[20:0],     // [31:11] Sampling output address
    7'h0,                           // [10:4]  Reserved
    sampling_output_addr_valid,     // [3]     Sampling output valid
    input_addr_valid,               // [2]     Input valid
    output_addr_ready,              // [1]     Output ready
    query_en                        // [0]     Epoch/query
  };

  // debug_counter_set_status: Counter set signals
  assign debug_counter_set_status = {
    counter_hot_addr[20:0],         // [63:43] Hot address
    counter_hot_cnt[11:0],          // [42:31] Hot count value
    19'h0,                          // [30:12] Reserved
    counter_hot_valid_cnt[7:0],     // [11:4]  Hot valid pulse count
    2'h0,                           // [3:2]   Reserved
    counter_mode,                   // [1]     0=LFU cache, 1=CM-sketch
    counter_hot_valid               // [0]     Hot valid signal
  };

  // debug_hotlist_internal: Pass through from hotlist
  assign debug_hotlist_internal = hotlist_debug;

endmodule

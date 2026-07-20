`timescale 1ns / 1ps

`ifndef XILINX
`include "cxl_type2_defines.svh.iv"
`else
`include "cxl_type2_defines.svh"
`endif

import ed_mc_axi_if_pkg::*;

module chmu_wrapper
#(
  // common parameter
  parameter ADDR_SIZE = 33,
  parameter DATA_SIZE = 21,
  
  // CHMU parameter
  parameter INDEX_SIZE     = 10,
  parameter NUM_WAY        = 4,
  parameter TAG_SIZE       = DATA_SIZE - INDEX_SIZE,
  parameter CNT_SIZE       = 12,
  parameter HOT_TH         = 10,  // Default hot threshold (now configurable via CSR[25])
  parameter LIST_SIZE      = 32,
  parameter SAMPLING_RATE  = 1
)
(
  input clk,
  input rstn,

  input ed_mc_axi_if_pkg::t_to_mc_axi4     cxlip2iafu_to_mc_axi4,
  input ed_mc_axi_if_pkg::t_from_mc_axi4   mc2iafu_from_mc_axi4,

  // hot tracker interface
  input                   query_en,
  input                   counter_mode,
  output                  query_ready,

  output                  mig_addr_cnt_en,
  output [ADDR_SIZE-1:0]  mig_addr_cnt,
  input                   mig_addr_cnt_ready,
  output                  mem_chan_rd_en,

  input  [ADDR_SIZE-1:0]  csr_addr_ub,
  input  [ADDR_SIZE-1:0]  csr_addr_lb,
  input  [11:0]           hot_threshold,  // Dynamic hot threshold from CSR[25]

  // Debug outputs for CSR visibility
  output logic [63:0]     debug_axi_status,      // AXI handshake signals
  output logic [63:0]     debug_fifo_status,     // FIFO status
  output logic [63:0]     debug_state_status,    // State machine status
  output logic [63:0]     debug_counter_status,  // Counter set status
  output logic [63:0]     debug_hotlist_status   // Hotlist status
);

// state
localparam STATE_IDLE   = 2'b00;
localparam STATE_AWADDR = 2'b01;
localparam STATE_ARADDR = 2'b10;
localparam EMPTY        = 10'd0;

//logic [ed_mc_axi_if_pkg::MC_AXI_WAC_ADDR_BW-1:0] awaddr;
//logic                                         awvalid;
//logic                                         awready;
logic [ed_mc_axi_if_pkg::MC_AXI_RAC_ADDR_BW-1:0] araddr;
logic                                         arvalid;
logic                                         arready;

logic                                         addr_within_range;

//logic                      awvalid_fifo;
logic                      arvalid_fifo;  
//logic                      awready_fifo;
logic                      arready_fifo; 
//logic [9:0]                aw_entry;                    
logic [9:0]                ar_entry;
logic                      araddr_full;
logic                      araddr_empty;

//logic                      awvalid_h2c;
//logic [ADDR_SIZE-1:0]      awaddr_h2c;
//logic                      awready_h2c;
logic                      arvalid_h2c;
logic [ADDR_SIZE-1:0]      araddr_h2c;
logic                      arready_h2c;

logic                      mig_addr_cnt_en_h2c;
logic [ADDR_SIZE-1:0]      mig_addr_cnt_h2c;
logic                      mig_addr_cnt_ready_h2c;

logic                      input_addr_valid;
logic [ADDR_SIZE-1:0]      input_addr;
logic                      input_addr_ready;

logic [1:0]                state, next_state; 


assign mig_addr_cnt_h2c_buf = mig_addr_cnt_h2c >> 1;
assign mig_addr_cnt = mig_addr_cnt_buf << 1;
logic [ADDR_SIZE-1:0] mig_addr_cnt_h2c_buf;
logic [ADDR_SIZE-1:0] mig_addr_cnt_buf;


always_comb
  begin
    //awaddr  = cxlip2iafu_to_mc_axi4.awaddr;
    //awvalid = cxlip2iafu_to_mc_axi4.awvalid;
    //awready = mc2iafu_from_mc_axi4.awready;

    // araddr  = cxlip2iafu_to_mc_axi4.araddr;
    // arvalid = cxlip2iafu_to_mc_axi4.arvalid;
    // arready = mc2iafu_from_mc_axi4.arready;
    araddr  = cxlip2iafu_to_mc_axi4.arvalid ? cxlip2iafu_to_mc_axi4.araddr : cxlip2iafu_to_mc_axi4.awaddr;
    arvalid = cxlip2iafu_to_mc_axi4.arvalid ? cxlip2iafu_to_mc_axi4.arvalid: cxlip2iafu_to_mc_axi4.awvalid;
    arready = cxlip2iafu_to_mc_axi4.arvalid ? mc2iafu_from_mc_axi4.arready :  mc2iafu_from_mc_axi4.awready;
  end

//assign awvalid_fifo = awvalid & awready;

logic [ADDR_SIZE-1:0]  csr_addr_ub_r;
logic [ADDR_SIZE-1:0]  csr_addr_lb_r;

//assign addr_within_range = (araddr[ADDR_SIZE-1:0] <= csr_addr_ub_r) & (araddr[ADDR_SIZE-1:0] >= csr_addr_lb_r);
assign addr_within_range = 1'b1;  // Accept all addresses (M5 reference approach - fixes high PA filtering issue)
assign arvalid_fifo = arvalid & arready & addr_within_range; //for simulation
assign mem_chan_rd_en = arvalid_fifo;

always_ff @ (posedge clk) begin
    if(!rstn) begin
        csr_addr_ub_r <= 'b0;
        csr_addr_lb_r <= 'b0;
    end else begin // 125MHz CSR, assume stable and no CDC
        csr_addr_ub_r <= csr_addr_ub;
        csr_addr_lb_r <= csr_addr_lb;
    end
end

always_ff @ (posedge clk or negedge rstn) begin
  if (!rstn) begin
    next_state <= 0;
  end
  else begin
    // first
    case(state)
      STATE_IDLE: begin
        //if (awvalid_h2c) begin
        //  next_state <= STATE_AWADDR;
        //end
        //else if (arvalid_h2c) begin
        if (arvalid_h2c) begin
          next_state <= STATE_ARADDR;
        end
        else begin
          next_state <= STATE_IDLE;
        end
      end
      /*
      STATE_AWADDR: begin
        if (input_addr_ready) begin
          if (ar_entry != EMPTY) begin
            next_state <= STATE_ARADDR;
          end
          else if (aw_entry != EMPTY) begin
            next_state <= STATE_AWADDR;
          end
          else begin
            next_state <= STATE_IDLE;
          end
        end
        else begin
          next_state <= STATE_AWADDR;
        end
      end
      */
      STATE_ARADDR: begin
        if (~arvalid_h2c) begin
          next_state <= STATE_IDLE;
        end
        else if (input_addr_ready) begin
          /*
          if (aw_entry != EMPTY) begin
            next_state <= STATE_AWADDR;
          end
          else if (ar_entry != EMPTY) begin
          */
          if (ar_entry != EMPTY) begin
            next_state <= STATE_ARADDR;
          end
          else begin
            next_state <= STATE_IDLE;
          end
        end
        else begin
          next_state <= STATE_ARADDR;
        end
      end
      default:;
    endcase
  end
end

// ============================================================================
// TIMING FIX: Combinational assignment of input_addr_valid
// ============================================================================
// ISSUE: The original code used registered input_addr_valid, causing a 1-cycle
//        delay. When transitioning from STATE_IDLE to STATE_ARADDR,
//        input_addr_valid would still be 0 from the previous STATE_IDLE,
//        preventing the handshake from completing.
//
// FIX: Make input_addr_valid combinational based on state and arvalid_h2c.
//      This allows immediate handshaking in STATE_ARADDR.
// ============================================================================

// Keep input_addr registered for timing
always_ff @ (posedge clk or negedge rstn) begin
  if (!rstn) begin
    input_addr  <= {ADDR_SIZE{1'b0}};
  end
  else begin
    case(state)
      STATE_IDLE: begin
        input_addr  <= araddr_h2c;
      end
      STATE_ARADDR: begin
        input_addr  <= araddr_h2c;
      end
      default:;
    endcase
  end
end

// Make input_addr_valid combinational - THIS IS THE FIX
always_comb begin
  input_addr_valid = 1'b0;
  case(state)
    STATE_IDLE: begin
      input_addr_valid = 1'b0;
    end
    STATE_ARADDR: begin
      input_addr_valid = arvalid_h2c;  // Directly pass through, no register delay
    end
    default: begin
      input_addr_valid = 1'b0;
    end
  endcase
end

always_comb begin
  arready_h2c = 1'b0;
  case(state)
    STATE_IDLE: begin
      //awready_h2c <= 1'b0;
      arready_h2c = 1'b0;
    end
    STATE_ARADDR: begin
      // FIX: Use arvalid_h2c directly instead of registered input_addr_valid
      // This allows handshaking on the first cycle of STATE_ARADDR
      if (input_addr_ready & arvalid_h2c)
        arready_h2c = 1'b1;
      else
        arready_h2c = 1'b0;
      //awready_h2c <= 1'b0;
    end
    default:;
  endcase
end
/*
always_ff @ (posedge clk or negedge rstn) begin
  if (!rstn) begin
    //awready_h2c <= 1'b0;
    arready_h2c <= 1'b0;
  end
  else begin
    case(state)
      STATE_IDLE: begin
        //awready_h2c <= 1'b0;
        arready_h2c <= 1'b0;
      end
      STATE_ARADDR: begin
        if (input_addr_valid & input_addr_ready & ~(query_en & (query_cmd == QUERY_MIG))) 
          arready_h2c <= 1'b1;
        else                  
          arready_h2c <= 1'b0;
        //awready_h2c <= 1'b0;
      end
      default:;
    endcase
  end
end
*/
/*
always_ff @ (posedge clk or negedge rstn) begin
  if (!rstn) begin
    aw_entry <= 10'd0;
  end
  else begin
    // entry + 1
    if (awvalid_fifo & awready_fifo & awvalid_h2c & awready_h2c) begin
      aw_entry <= aw_entry;
    end
    else if (awvalid_fifo & awready_fifo) begin
      aw_entry <= aw_entry + 10'd1;
    end
    else if (awvalid_h2c & awready_h2c) begin
      aw_entry <= aw_entry - 10'd1;
    end
    else begin
      aw_entry <= aw_entry;
    end
  end
end
*/

always_ff @ (posedge clk or negedge rstn) begin
  if (!rstn) begin
    ar_entry <= 10'd0;
  end
  else begin
    // entry + 1
    if (arvalid_fifo & arready_fifo & arvalid_h2c & arready_h2c) begin
      ar_entry <= ar_entry;
    end
    else if (arvalid_fifo & arready_fifo) begin
      ar_entry <= ar_entry + 10'd1;
    end
    else if (arvalid_h2c & arready_h2c) begin
      ar_entry <= ar_entry - 10'd1;
    end
    else begin
      ar_entry <= ar_entry;
    end
  end
end

/*
always_ff @ (posedge clk or negedge rstn) begin
  if (!rstn) begin
    input_addr_valid <= 1'b0;
  end
  else begin
    input_addr_valid <= awvalid_h2c | arvalid_h2c;
  end
end
*/
always_ff @ (posedge clk or negedge rstn) begin
  if (!rstn) begin
    state <= STATE_IDLE;
  end
  else begin
    state <= next_state;
  end
end

// axis FIFO to CXL IP
/*
axis_data_fifo_0 // hot to cxl(h2c), cxl to hot(c2h)
  awaddr_fifo
(
  .s_axis_aclk    ( clk            ),
  .s_axis_aresetn ( rstn           ),
  .s_axis_tready  ( awready_fifo ),//( awready ),
  .m_axis_tready  ( awready_h2c ),
  .s_axis_tvalid  ( awvalid_fifo ),
  .s_axis_tdata   ( awaddr      ),
  //.s_axis_tkeep   ( s_axis_h2c_tkeep        ),
  //.s_axis_tlast   ( s_axis_h2c_tlast        ),
  .m_axis_tvalid  ( awvalid_h2c  ),
  .m_axis_tdata   ( awaddr_h2c   )
  //.m_axis_tkeep   ( s_axis_h2c_tkeep_fifo   ),
  //.m_axis_tlast   ( s_axis_h2c_tlast_fifo   )
);
*/

`ifndef XILINX
axis_data_fifo #(.DATA_WIDTH(ADDR_SIZE))
`else
axis_data_fifo_0 // hot to cxl(h2c), cxl to hot(c2h)
`endif
  araddr_fifo
(
  .s_axis_aclk    ( clk            ),
  .s_axis_aresetn ( rstn           ),
  .s_axis_tready  ( arready_fifo),//( arready ),
  .m_axis_tready  ( arready_h2c ),
  .s_axis_tvalid  ( arvalid_fifo ),
  .s_axis_tdata   ( {{(ADDR_SIZE-DATA_SIZE){1'b0}}, araddr[ADDR_SIZE-1:ADDR_SIZE-DATA_SIZE]} ),
  .m_axis_tvalid  ( arvalid_h2c  ),
  .m_axis_tdata   ( araddr_h2c   )
);

// axis FIFO to CXL IP
`ifndef XILINX
axis_data_fifo #(.DATA_WIDTH(ADDR_SIZE))
`else
axis_data_fifo_0 // hot to cxl(h2c), cxl to hot(c2h)
`endif
  mig_addr_cnt_fifo
(
  .s_axis_aclk    ( clk            ),
  .s_axis_aresetn ( rstn           ),
  .s_axis_tready  ( mig_addr_cnt_ready_h2c ),
  .m_axis_tready  ( mig_addr_cnt_ready        ),
  .s_axis_tvalid  ( mig_addr_cnt_en_h2c ),
  .s_axis_tdata   ( mig_addr_cnt_h2c_buf  ),
  .m_axis_tvalid  ( mig_addr_cnt_en  ),
  .m_axis_tdata   ( mig_addr_cnt_buf        )
);



// Debug signals from chmu_tracker
logic [63:0] tracker_debug_status;
logic [63:0] tracker_sampling_status;
logic [63:0] tracker_counter_set_status;
logic [63:0] tracker_hotlist_internal;

// hot tracker
chmu_tracker #(
  .ADDR_SIZE(DATA_SIZE),
  .INDEX_SIZE(INDEX_SIZE),
  .NUM_WAY(NUM_WAY),
  .TAG_SIZE(TAG_SIZE),
  .CNT_SIZE(CNT_SIZE),
  .HOT_TH(HOT_TH),
  .LIST_SIZE(LIST_SIZE),
  .SAMPLING_RATE(SAMPLING_RATE)
)
u_chmu_tracker (
  .clk                    (clk),
  .rst_n                  (rstn),

  .input_addr             (input_addr),
  .input_addr_valid       (input_addr_valid),
  .output_addr_ready      (input_addr_ready),

  .query_en               (query_en),
  .counter_mode           (counter_mode),
  .query_ready            (query_ready),

  .mig_addr_cnt_en        (mig_addr_cnt_en_h2c),
  .mig_addr_cnt           (mig_addr_cnt_h2c),
  .mig_addr_cnt_ready     (mig_addr_cnt_ready_h2c),

  .hot_threshold          (hot_threshold),

  // Debug outputs from tracker
  .debug_tracker_status    (tracker_debug_status),
  .debug_sampling_status   (tracker_sampling_status),
  .debug_counter_set_status(tracker_counter_set_status),
  .debug_hotlist_internal  (tracker_hotlist_internal)
);

// ============================================================================
// Debug Signal Assignments for CSR Monitoring
// ============================================================================

// ===== All Debug Counter Declarations =====
logic [31:0] arvalid_pulse_counter;      // Counts arvalid & arready pulses
logic [31:0] arvalid_only_counter;       // Counts arvalid alone (no ready)
logic [31:0] fifo_write_counter;         // Counts FIFO writes
logic [31:0] fifo_read_counter;          // Counts FIFO reads
logic [31:0] tracker_input_counter;      // Counts tracker input handshakes
logic [31:0] hot_page_counter;           // Counts hot page detections
logic [31:0] query_counter;              // Counts query_en pulses
logic [31:0] state_araddr_counter;       // Counts times entering STATE_ARADDR
logic [31:0] arvalid_h2c_counter;        // Counts arvalid_h2c assertions
logic [31:0] input_valid_no_ready_cnt;   // input_addr_valid but NOT input_addr_ready

// ===== Counter Implementations =====

// Counter 0: arvalid pulses (AXI handshakes complete)
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    arvalid_pulse_counter <= 32'h0;
  end else if (arvalid & arready) begin
    arvalid_pulse_counter <= arvalid_pulse_counter + 1;
  end
end

// Counter 0b: arvalid alone (may not have arready)
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    arvalid_only_counter <= 32'h0;
  end else if (arvalid) begin
    arvalid_only_counter <= arvalid_only_counter + 1;
  end
end

// Counter 1: FIFO writes
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    fifo_write_counter <= 32'h0;
  end else if (arvalid_fifo & arready_fifo) begin
    fifo_write_counter <= fifo_write_counter + 1;
  end
end

// Counter 2: FIFO reads
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    fifo_read_counter <= 32'h0;
  end else if (arvalid_h2c & arready_h2c) begin
    fifo_read_counter <= fifo_read_counter + 1;
  end
end

// Counter 3: Tracker inputs (handshake complete)
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    tracker_input_counter <= 32'h0;
  end else if (input_addr_valid & input_addr_ready) begin
    tracker_input_counter <= tracker_input_counter + 1;
  end
end

// Counter 4: Hot page detections
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    hot_page_counter <= 32'h0;
  end else if (mig_addr_cnt_en_h2c & mig_addr_cnt_ready_h2c) begin
    hot_page_counter <= hot_page_counter + 1;
  end
end

// Counter 5: Query pulses
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    query_counter <= 32'h0;
  end else if (query_en) begin
    query_counter <= query_counter + 1;
  end
end

// Counter 6: State transitions to STATE_ARADDR
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    state_araddr_counter <= 32'h0;
  end else if (state == STATE_IDLE && next_state == STATE_ARADDR) begin
    state_araddr_counter <= state_araddr_counter + 1;
  end
end

// Counter 7: arvalid_h2c assertions (FIFO output valid)
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    arvalid_h2c_counter <= 32'h0;
  end else if (arvalid_h2c) begin
    arvalid_h2c_counter <= arvalid_h2c_counter + 1;
  end
end

// Counter 8: input_addr_valid asserted but input_addr_ready is 0
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    input_valid_no_ready_cnt <= 32'h0;
  end else if (input_addr_valid & ~input_addr_ready) begin
    input_valid_no_ready_cnt <= input_valid_no_ready_cnt + 1;
  end
end

// Capture first non-zero address seen
logic [32:0] first_valid_addr;
logic first_addr_captured;
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    first_valid_addr <= 33'h0;
    first_addr_captured <= 1'b0;
  end else if (arvalid & arready & ~first_addr_captured) begin
    first_valid_addr <= araddr[32:0];
    first_addr_captured <= 1'b1;
  end
end

// Capture last valid address seen
logic [32:0] last_valid_addr;
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    last_valid_addr <= 33'h0;
  end else if (arvalid & arready) begin
    last_valid_addr <= araddr[32:0];
  end
end

// ===== Debug CSR Assignments =====

// Debug AXI Status (CSR[26]) - Track incoming AXI signals and first stage counters
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    debug_axi_status <= 64'h0;
  end else begin
    debug_axi_status <= {
      arvalid_pulse_counter,     // [63:32] - Counter of arvalid & arready pulses
      arvalid_only_counter[15:0],// [31:16] - Counter of arvalid alone
      ar_entry[9:0],             // [15:6]  - FIFO entry count
      2'b0,                      // [5:4]   - reserved
      arvalid_h2c,               // [3]     - FIFO output valid
      arready_h2c,               // [2]     - FIFO output ready
      arvalid,                   // [1]     - AXI arvalid from CXL
      arready                    // [0]     - AXI arready to CXL
    };
  end
end

// Debug FIFO Status (CSR[27]) - Track FIFO and state machine
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    debug_fifo_status <= 64'h0;
  end else begin
    debug_fifo_status <= {
      fifo_write_counter[15:0],  // [63:48] - FIFO write count
      fifo_read_counter[15:0],   // [47:32] - FIFO read count
      state_araddr_counter[9:0], // [31:22] - STATE_ARADDR entry count
      mem_chan_rd_en,            // [21]    - mem_chan_rd_en (same as arvalid_fifo)
      query_ready,               // [20]    - Query ready from hotlist
      query_en,                  // [19]    - Query enable input
      addr_within_range,         // [18]    - Address filter result
      araddr_empty,              // [17]    - FIFO empty
      araddr_full,               // [16]    - FIFO full
      arvalid_h2c_counter[7:0],  // [15:8]  - arvalid_h2c counter
      arvalid_fifo,              // [7]     - FIFO input valid
      arready_fifo,              // [6]     - FIFO input ready
      arvalid_h2c,               // [5]     - FIFO output valid
      arready_h2c,               // [4]     - FIFO output ready
      input_addr_valid,          // [3]     - Input valid to tracker
      input_addr_ready,          // [2]     - Input ready from tracker
      state[1:0]                 // [1:0]   - State machine
    };
  end
end

// Debug State Status (CSR[28]) - Tracker internal status from chmu_tracker
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    debug_state_status <= 64'h0;
  end else begin
    debug_state_status <= tracker_debug_status;  // Pass through from tracker
  end
end

// Debug Counter Status (CSR[29]) - Counter set and sampling status
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    debug_counter_status <= 64'h0;
  end else begin
    debug_counter_status <= tracker_counter_set_status;  // Pass through from tracker
  end
end

// Debug Hotlist Status (CSR[30]) - Hotlist internal status
always_ff @(posedge clk or negedge rstn) begin
  if (!rstn) begin
    debug_hotlist_status <= 64'h0;
  end else begin
    debug_hotlist_status <= tracker_hotlist_internal;  // Pass through from tracker->hotlist
  end
end

endmodule

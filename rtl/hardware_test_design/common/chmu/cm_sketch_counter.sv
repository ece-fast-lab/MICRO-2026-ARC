//=============================================================================
// CM-Sketch Counter — valid-bit based lazy reset, slack-optimized version
//
// Latency:
//   Cycle 0: hash computation + SRAM read scheduling
//   Cycle 1: counter read + increment + min reduction, register compare inputs
//   Cycle 2: threshold compare + output
//=============================================================================

module cm_sketch_counter #(
  parameter ADDR_SIZE  = 21,
  parameter INDEX_SIZE = 10,
  parameter NUM_WAY    = 4,
  parameter TAG_SIZE   = ADDR_SIZE - INDEX_SIZE,
  parameter CNT_SIZE   = 12,
  parameter HOT_TH     = 10
)(
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic [ADDR_SIZE-1:0] input_addr,
  input  logic                 input_addr_valid,
  input  logic                 epoch,

  input  logic [11:0]          hot_threshold,

  output logic [ADDR_SIZE-1:0] output_addr,
  output logic [CNT_SIZE-1:0]  output_cnt,
  output logic                 output_valid
);

  localparam NUM_HASH    = 4;
  localparam LOG_ENTRIES = 11;                  // log2(2048)
  localparam NUM_ENTRIES = 1 << LOG_ENTRIES;    // 2048
  localparam SK_CNT_W    = 12;
  localparam ENTRY_W     = SK_CNT_W;
  localparam [SK_CNT_W-1:0] CNT_MAX = {SK_CNT_W{1'b1}};

  // --------------------------------------------------------------------------
  // Lightweight hash mix
  // --------------------------------------------------------------------------
  function automatic [LOG_ENTRIES-1:0] hash_mix (
    input logic [ADDR_SIZE-1:0] addr_in,
    input logic [31:0]          seed
  );
    logic [31:0] x;
    begin
      x = {{(32-ADDR_SIZE){1'b0}}, addr_in} ^ seed;
      x = x ^ (x >> 16);
      x = x ^ (x << 7);
      x = x ^ (x >> 11);
      x = x ^ (x << 3);
      hash_mix = x[LOG_ENTRIES-1:0] ^ x[31 -: LOG_ENTRIES];
    end
  endfunction

  logic [LOG_ENTRIES-1:0] hash_idx [0:NUM_HASH-1];

  always_comb begin
    hash_idx[0] = hash_mix(input_addr, 32'h9E3779B9);
    hash_idx[1] = hash_mix(input_addr, 32'h7F4A7C15);
    hash_idx[2] = hash_mix(input_addr, 32'h94D049BB);
    hash_idx[3] = hash_mix(input_addr, 32'hD2511F53);
  end

  // --------------------------------------------------------------------------
  // Sequential valid clear on epoch
  // --------------------------------------------------------------------------
  logic                   clear_busy;
  logic [LOG_ENTRIES-1:0] clear_addr;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      clear_busy <= 1'b0;
      clear_addr <= '0;
    end
    else if (epoch) begin
      clear_busy <= 1'b1;
      clear_addr <= '0;
    end
    else if (clear_busy) begin
      if (clear_addr == NUM_ENTRIES-1) begin
        clear_busy <= 1'b0;
        clear_addr <= '0;
      end
      else begin
        clear_addr <= clear_addr + 1'b1;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Pipeline stage 0: capture input and hashes
  // --------------------------------------------------------------------------
  logic                   pipe_valid;
  logic [ADDR_SIZE-1:0]   pipe_addr;
  logic [LOG_ENTRIES-1:0] pipe_hash [0:NUM_HASH-1];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pipe_valid <= 1'b0;
      pipe_addr  <= '0;
    end
    else if (epoch || clear_busy) begin
      pipe_valid <= 1'b0;
      pipe_addr  <= '0;
    end
    else begin
      pipe_valid <= input_addr_valid;
      pipe_addr  <= input_addr;
      for (int i = 0; i < NUM_HASH; i++)
        pipe_hash[i] <= hash_idx[i];
    end
  end

  // --------------------------------------------------------------------------
  // Shared address mux for read path
  // --------------------------------------------------------------------------
  logic [LOG_ENTRIES-1:0] sram_addr [0:NUM_HASH-1];

  always_comb begin
    for (int i = 0; i < NUM_HASH; i++) begin
      if (pipe_valid)
        sram_addr[i] = pipe_hash[i];
      else
        sram_addr[i] = hash_idx[i];
    end
  end

  // --------------------------------------------------------------------------
  // Counter SRAMs
  // --------------------------------------------------------------------------
  logic [ENTRY_W-1:0] sram_rd      [0:NUM_HASH-1];
  logic [ENTRY_W-1:0] sram_wr_data [0:NUM_HASH-1];
  logic               sram_wr_en;

  assign sram_wr_en = pipe_valid & ~clear_busy & ~epoch;

  genvar gi;
  generate
    for (gi = 0; gi < NUM_HASH; gi++) begin : SKETCH_ROW
      (* ramstyle = "M20K" *) logic [ENTRY_W-1:0] mem [0:NUM_ENTRIES-1];

      always_ff @(posedge clk) begin
        if (sram_wr_en)
          mem[pipe_hash[gi]] <= sram_wr_data[gi];
        sram_rd[gi] <= mem[sram_addr[gi]]; // read-first style
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Valid memories: 1-bit per entry, sequentially cleared on epoch
  // --------------------------------------------------------------------------
  logic valid_rd [0:NUM_HASH-1];

  generate
    for (gi = 0; gi < NUM_HASH; gi++) begin : VALID_ROW
      (* ramstyle = "MLAB" *) logic valid_mem [0:NUM_ENTRIES-1];

      always_ff @(posedge clk) begin
        if (clear_busy)
          valid_mem[clear_addr] <= 1'b0;
        else if (sram_wr_en)
          valid_mem[pipe_hash[gi]] <= 1'b1;

        valid_rd[gi] <= valid_mem[sram_addr[gi]];
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Stage 1 combinational work: old/new count and min reduction
  // --------------------------------------------------------------------------
  logic [SK_CNT_W-1:0] old_cnt [0:NUM_HASH-1];
  logic [SK_CNT_W-1:0] new_cnt [0:NUM_HASH-1];
  logic [SK_CNT_W-1:0] old_min01, old_min23, old_min;
  logic [SK_CNT_W-1:0] new_min01, new_min23, new_min;
  logic [SK_CNT_W-1:0] thresh;

  assign thresh = hot_threshold[SK_CNT_W-1:0];

  always_comb begin
    for (int i = 0; i < NUM_HASH; i++) begin
      old_cnt[i]     = valid_rd[i] ? sram_rd[i] : '0;
      new_cnt[i]     = (&old_cnt[i]) ? old_cnt[i] : (old_cnt[i] + 1'b1);
      sram_wr_data[i] = new_cnt[i];
    end

    old_min01 = (old_cnt[0] < old_cnt[1]) ? old_cnt[0] : old_cnt[1];
    old_min23 = (old_cnt[2] < old_cnt[3]) ? old_cnt[2] : old_cnt[3];
    old_min   = (old_min01  < old_min23)  ? old_min01  : old_min23;

    new_min01 = (new_cnt[0] < new_cnt[1]) ? new_cnt[0] : new_cnt[1];
    new_min23 = (new_cnt[2] < new_cnt[3]) ? new_cnt[2] : new_cnt[3];
    new_min   = (new_min01  < new_min23)  ? new_min01  : new_min23;
  end

  // --------------------------------------------------------------------------
  // Pipeline stage 1 register: isolate reduction from threshold compare
  // --------------------------------------------------------------------------
  logic                 cmp_valid;
  logic [ADDR_SIZE-1:0] cmp_addr;
  logic [SK_CNT_W-1:0]  cmp_old_min;
  logic [SK_CNT_W-1:0]  cmp_new_min;
  logic [SK_CNT_W-1:0]  cmp_thresh;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cmp_valid   <= 1'b0;
      cmp_addr    <= '0;
      cmp_old_min <= '0;
      cmp_new_min <= '0;
      cmp_thresh  <= SK_CNT_W'(HOT_TH);
    end
    else if (epoch || clear_busy) begin
      cmp_valid   <= 1'b0;
      cmp_addr    <= '0;
      cmp_old_min <= '0;
      cmp_new_min <= '0;
      cmp_thresh  <= '0;
    end
    else begin
      cmp_valid   <= pipe_valid;
      cmp_addr    <= pipe_addr;
      cmp_old_min <= old_min;
      cmp_new_min <= new_min;
      cmp_thresh  <= thresh;
    end
  end

  // --------------------------------------------------------------------------
  // Pipeline stage 2: threshold crossing output
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      output_valid <= 1'b0;
      output_addr  <= '0;
      output_cnt   <= '0;
    end
    else if (epoch || clear_busy) begin
      output_valid <= 1'b0;
      output_addr  <= '0;
      output_cnt   <= '0;
    end
    else if (cmp_valid) begin
      if ((cmp_old_min < cmp_thresh) && (cmp_new_min >= cmp_thresh)) begin
        output_valid <= 1'b1;
        output_addr  <= cmp_addr;
        output_cnt   <= cmp_new_min;
      end
      else begin
        output_valid <= 1'b0;
        output_addr  <= '0;
        output_cnt   <= '0;
      end
    end
    else begin
      output_valid <= 1'b0;
      output_addr  <= '0;
      output_cnt   <= '0;
    end
  end

endmodule

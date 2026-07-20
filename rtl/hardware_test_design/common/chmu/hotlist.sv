module hotlist #(
  parameter ADDR_SIZE      = 21,
  parameter CNT_SIZE       = 12,
  parameter LIST_SIZE      = 32
)(
  input  logic                          clk,
  input  logic                          rst_n,

  input  logic [ADDR_SIZE-1:0]          input_addr,
  input  logic [CNT_SIZE-1:0]           input_cnt,
  input  logic                          input_valid,

  input  logic                          query_en,
  output logic                          query_ready,

  output  logic                         mig_addr_cnt_ready,
  output logic [ADDR_SIZE+CNT_SIZE-1:0] mig_addr_cnt,
  input logic                           mig_addr_cnt_en,

  // ===== DEBUG OUTPUT =====
  output logic [63:0]                   debug_status
);

  localparam PTR_WIDTH = (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE);

  typedef struct packed {
    logic [ADDR_SIZE-1:0] addr;
    logic [CNT_SIZE-1:0]  cnt;
  } entry_t;

  entry_t queue [0:LIST_SIZE-1];

  logic                 empty, full;
  logic [PTR_WIDTH-1:0] rd_ptr, wr_ptr;
  logic [PTR_WIDTH:0]   count;
  logic push, pop;

  logic                 output_en;
  logic [ADDR_SIZE-1:0] output_addr;
  logic [CNT_SIZE-1:0]  output_cnt;

  /*************** Control hotlist ***************/
  assign empty = (count == 0);
  assign full  = (count == LIST_SIZE);
  assign push = input_valid && !full;
  //assign pop = query_en && query_ready;
  assign pop = query_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_ptr <= '0;
      wr_ptr <= '0;
      count  <= '0;
    end else begin
      if (push) begin
        queue[wr_ptr].addr <= input_addr;
        queue[wr_ptr].cnt  <= input_cnt;
        wr_ptr <= (wr_ptr == LIST_SIZE-1) ? '0 : (wr_ptr + 1'b1);
      end
      if (pop) begin
        rd_ptr <= (rd_ptr == LIST_SIZE-1) ? '0 : (rd_ptr + 1'b1);
      end

      case ({push, pop})
        2'b00: count <= count;
        2'b10: count <= count + 1'b1;       // push only
        2'b01: count <= count - 1'b1;       // pop only
        2'b11: count <= count;
      endcase
    end
  end

  /*************** Output logic ***************/
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      output_en <= 1'b0;
      output_addr  <= '0;
      output_cnt   <= '0;
    end else begin
      if (pop) begin
        output_en <= 1'b1;
        output_addr  <= queue[rd_ptr].addr;
        output_cnt   <= queue[rd_ptr].cnt;
      end
      else if (output_en & mig_addr_cnt_en) begin // handshake
        output_en <= 1'b0;    
      end
    end
  end

  assign mig_addr_cnt = {output_addr, output_cnt};
  assign mig_addr_cnt_ready = output_en;
  assign query_ready = !empty & !output_en;

  // ============================================================================
  // DEBUG: Hotlist internal state and counters
  // ============================================================================

  // Counter: Push operations (hot pages added to queue)
  logic [15:0] push_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      push_cnt <= 16'h0;
    else if (push)
      push_cnt <= push_cnt + 1;
  end

  // Counter: Pop operations (hot pages read from queue)
  logic [15:0] pop_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pop_cnt <= 16'h0;
    else if (pop)
      pop_cnt <= pop_cnt + 1;
  end

  // Counter: Input valid pulses (from counter_set)
  logic [15:0] input_valid_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      input_valid_cnt <= 16'h0;
    else if (input_valid)
      input_valid_cnt <= input_valid_cnt + 1;
  end

  // Counter: Full condition hits (dropped hot pages)
  logic [15:0] full_drop_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      full_drop_cnt <= 16'h0;
    else if (input_valid & full)
      full_drop_cnt <= full_drop_cnt + 1;
  end

  // Debug status output
  assign debug_status = {
    push_cnt[15:0],           // [63:48] Push count (entries added)
    pop_cnt[15:0],            // [47:32] Pop count (entries read)
    input_valid_cnt[7:0],     // [31:24] Input valid count
    full_drop_cnt[7:0],       // [23:16] Dropped due to full
    count[5:0],               // [15:10] Current queue count
    2'b0,                     // [9:8]   Reserved
    empty,                    // [7]     Queue empty
    full,                     // [6]     Queue full
    query_ready,              // [5]     Ready to be queried
    output_en,                // [4]     Output enabled
    input_valid,              // [3]     Input valid signal
    query_en,                 // [2]     Query enable
    push,                     // [1]     Push happening
    pop                       // [0]     Pop happening
  };

endmodule
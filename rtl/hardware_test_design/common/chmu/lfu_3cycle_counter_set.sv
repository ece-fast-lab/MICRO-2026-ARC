//=============================================================================
// Copyright (C) 2025 Eojin Na, Seoul National University,
// Scalable Computer Architecture Lab. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//=============================================================================
// Author       : Eojin Na
// Contact      : eojin.na@scale.snu.ac.kr
//=============================================================================
//
// NOTES (entry-count 유지):
//   total_entries = (1<<INDEX_SIZE) * NUM_WAY
//   예: 기존 INDEX_SIZE=10, NUM_WAY=4 (4096 entries) 기준이면
//     - 8-way  유지: INDEX_SIZE=9,  NUM_WAY=8
//     - 16-way 유지: INDEX_SIZE=8,  NUM_WAY=16
//
// This version removes NUM_WAY=4 hardcodes (hit/alloc encoder) and fixes
// forwarding to only the updated way (safe for 8/16-way).
//=============================================================================

module lfu_3cycle_counter_set #(
  parameter int ADDR_SIZE      = 21,                      // DPA unit size = 4KB, address space = 8GB (33 - 12 = 21)
  parameter int INDEX_SIZE     = 10,                      // # of sets
  parameter int NUM_WAY        = 4,
  parameter int TAG_SIZE       = ADDR_SIZE - INDEX_SIZE,
  parameter int CNT_SIZE       = 12,
  parameter int HOT_TH         = 10                      // Default hot threshold (now configurable via CSR[25])
)(
  input  logic                 clk,
  input  logic                 rst_n,

  input  logic [ADDR_SIZE-1:0] input_addr,
  input  logic                 input_addr_valid,
  input  logic                 epoch,

  input  logic [11:0]          hot_threshold,  // Dynamic hot threshold from CSR[25]

  output logic [ADDR_SIZE-1:0] output_addr,
  output logic [CNT_SIZE-1:0]  output_cnt,
  output logic                 output_valid
);

  localparam int NUM_SET = 1 << INDEX_SIZE;

  genvar i;

  /*************** Types ***************/
  typedef struct packed {
    logic [TAG_SIZE-1:0]   tag;
    logic [CNT_SIZE-1:0]   cnt;
  } way_t;

  /*************** Helper: saturating increment (wrap 방지) ***************/
  function automatic logic [CNT_SIZE-1:0] sat_inc(input logic [CNT_SIZE-1:0] x);
    if (x == {CNT_SIZE{1'b1}}) sat_inc = x;
    else                      sat_inc = x + {{(CNT_SIZE-1){1'b0}}, 1'b1};
  endfunction

  /*************** Latch & pipeline regs ***************/
  logic                  valid, valid_d1, hot_valid;
  logic [ADDR_SIZE-1:0]  addr, addr_d1, addr_d2, hot_addr;
  logic [TAG_SIZE-1:0]   addr_tag, addr_tag_d1;
  logic [INDEX_SIZE-1:0] input_addr_index, addr_index, addr_index_d1, addr_index_d2;
  logic [CNT_SIZE-1:0]   hot_cnt;

  way_t                        way_wdata, way_wdata_d1, hit_wdata, hit_wdata_d1, alloc_wdata;
  way_t [NUM_WAY-1:0]          way_output, way_rdata, way_rdata_d1;

  logic way_valid [NUM_SET][NUM_WAY-1:0];

  logic [NUM_WAY-1:0]          way_wren, way_match, way_free;
  logic                        is_forward, hit_any, alloc_any, hit_any_d1, alloc_any_d1, hit_any_d2, alloc_any_d2;
  logic                        collision, collision_d1, collision_d2;

  logic [$clog2(NUM_WAY)-1:0]  hit_way_enc, alloc_way_enc, evict_way_enc;
  logic [$clog2(NUM_WAY)-1:0]  hit_way_enc_d1, alloc_way_enc_d1, evict_way_enc_d1;
  logic [$clog2(NUM_WAY)-1:0]  hit_way_enc_d2, alloc_way_enc_d2, evict_way_enc_d2;
  logic [$clog2(NUM_WAY)-1:0]  bram_hit_way_enc;

  logic [$clog2(NUM_WAY)-1:0]  fwd_way_enc;

  logic invalidate_previous_value;
  logic [CNT_SIZE-1:0] min_cnt;

  /*************** Index/tag slicing ***************/
  assign input_addr_index = input_addr[INDEX_SIZE-1:0];
  assign addr_index       = addr[INDEX_SIZE-1:0];
  assign addr_index_d1    = addr_d1[INDEX_SIZE-1:0];
  assign addr_index_d2    = addr_d2[INDEX_SIZE-1:0];
  assign addr_tag         = addr[ADDR_SIZE-1 -: TAG_SIZE];
  assign addr_tag_d1      = addr_d1[ADDR_SIZE-1 -: TAG_SIZE];

  /*************** Latch input ***************/
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid <= 1'b0;
      addr  <= {ADDR_SIZE{1'b0}};
    end
    else if (epoch) begin
      valid <= 1'b0;
      addr  <= {ADDR_SIZE{1'b0}};
    end
    else if (input_addr_valid) begin
      valid <= input_addr_valid;
      addr  <= input_addr;
    end
    else begin
      valid <= 1'b0;
    end
  end

  /*************** Pipeline regs ***************/
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_d1         <= 1'b0;
      addr_d1          <= {ADDR_SIZE{1'b0}};
      addr_d2          <= {ADDR_SIZE{1'b0}};
      hit_way_enc_d1   <= '0;
      hit_way_enc_d2   <= '0;
      alloc_way_enc_d1 <= '0;
      alloc_way_enc_d2 <= '0;
      evict_way_enc_d1 <= '0;
      evict_way_enc_d2 <= '0;
      hit_any_d1       <= '0;
      hit_any_d2       <= '0;
      alloc_any_d1     <= '0;
      alloc_any_d2     <= '0;
      collision_d1     <= '0;
      collision_d2     <= '0;
      hit_wdata_d1     <= '0;
      for (int w = 0; w < NUM_WAY; w++) begin
        way_rdata_d1[w] <= '0;
      end
      way_wdata_d1     <= '0;
    end
    else if (epoch) begin
      valid_d1         <= 1'b0;
      addr_d1          <= {ADDR_SIZE{1'b0}};
      addr_d2          <= {ADDR_SIZE{1'b0}};
      hit_way_enc_d1   <= '0;
      hit_way_enc_d2   <= '0;
      alloc_way_enc_d1 <= '0;
      alloc_way_enc_d2 <= '0;
      evict_way_enc_d1 <= '0;
      evict_way_enc_d2 <= '0;
      hit_any_d1       <= '0;
      hit_any_d2       <= '0;
      alloc_any_d1     <= '0;
      alloc_any_d2     <= '0;
      collision_d1     <= '0;
      collision_d2     <= '0;
      hit_wdata_d1     <= '0;
      for (int w = 0; w < NUM_WAY; w++) begin
        way_rdata_d1[w] <= '0;
      end
      way_wdata_d1     <= '0;
    end
    else begin
      valid_d1         <= valid;
      addr_d1          <= addr;
      addr_d2          <= addr_d1;
      hit_way_enc_d1   <= hit_way_enc;
      hit_way_enc_d2   <= hit_way_enc_d1;
      alloc_way_enc_d1 <= alloc_way_enc;
      alloc_way_enc_d2 <= alloc_way_enc_d1;
      evict_way_enc_d1 <= evict_way_enc;
      evict_way_enc_d2 <= evict_way_enc_d1;
      hit_any_d1       <= hit_any;
      hit_any_d2       <= hit_any_d1;
      alloc_any_d1     <= alloc_any;
      alloc_any_d2     <= alloc_any_d1;
      collision_d1     <= collision;
      collision_d2     <= collision_d1;
      hit_wdata_d1     <= hit_wdata;
      for (int w = 0; w < NUM_WAY; w++) begin
        way_rdata_d1[w] <= way_rdata[w];
      end
      way_wdata_d1     <= way_wdata;
    end
  end

  /*************** Cycle 1: Read & hit/alloc/collision ***************/
  assign is_forward = (hit_any_d2 || alloc_any_d2 || collision_d2) && (addr == addr_d2);
  assign invalidate_previous_value = collision_d2 & (addr_index == addr_index_d2);

  // Which way was updated in the previous op that we want to forward?
  assign fwd_way_enc = hit_any_d2   ? hit_way_enc_d2 :
                       alloc_any_d2 ? alloc_way_enc_d2 :
                                      evict_way_enc_d1;

  // Read mux + forward only the updated way (safe for 8/16-way)
  always_comb begin
    for (int w = 0; w < NUM_WAY; w++) begin
      if (valid) begin
        if (is_forward && (w[$clog2(NUM_WAY)-1:0] == fwd_way_enc)) begin
          way_rdata[w] = way_wdata_d1;
        end
        else begin
          way_rdata[w] = way_output[w];
        end
      end
      else begin
        way_rdata[w] = '0;
      end
    end
  end

  always_comb begin
    for (int w = 0; w < NUM_WAY; w++) begin
      way_match[w] = way_valid[addr_index][w]
                  && (way_rdata[w].tag == addr_tag)
                  && valid
                  && ~(invalidate_previous_value && (w[$clog2(NUM_WAY)-1:0] == evict_way_enc_d2));
      way_free[w]  = ~way_valid[addr_index][w] && valid;
    end
  end

  assign hit_any   = is_forward | (|way_match);
  assign alloc_any = (~hit_any) && (|way_free);
  assign collision = valid && !hit_any && !alloc_any;

  // Generic priority encoder for hit (replaces 4-way hardcode)
  always_comb begin
    bram_hit_way_enc = '0;
    for (int w = NUM_WAY; w > 0; w--) begin
      if (way_match[w-1]) begin
        bram_hit_way_enc = w - 1;
      end
    end
  end

  // Select hit_way_enc with forwarding behavior preserved
  always_comb begin
    if (!is_forward) begin
      hit_way_enc = bram_hit_way_enc;
    end
    else begin
      hit_way_enc = (hit_any_d2   ? hit_way_enc_d2
                 :  alloc_any_d2 ? alloc_way_enc_d2
                                : evict_way_enc_d1);
    end
  end

  // Generic priority encoder for allocate (replaces 4-way hardcode)
  always_comb begin
    alloc_way_enc = '0;
    for (int w = NUM_WAY; w > 0; w--) begin
      if (way_free[w-1]) begin
        alloc_way_enc = w - 1;
      end
    end
  end

  /*************** LFU eviction (PLRU -> LFU) ***************/
  // Choose victim way with the smallest cnt among valid ways in the set.
  always_comb begin
    evict_way_enc = '0;
    min_cnt       = {CNT_SIZE{1'b1}};

    for (int w = 0; w < NUM_WAY; w++) begin
      if (valid && way_valid[addr_index][w]) begin
        if (way_rdata[w].cnt < min_cnt) begin
          min_cnt       = way_rdata[w].cnt;
          evict_way_enc = w[$clog2(NUM_WAY)-1:0];
        end
      end
    end
  end

  /*************** Cycle 2: Compute wdata/wren, valid update ***************/
  always_comb begin
    hit_wdata.tag   = addr_tag_d1;
    hit_wdata.cnt   = sat_inc(way_rdata_d1[hit_way_enc_d1].cnt); // +1 (saturating)
    alloc_wdata.tag = addr_tag_d1;
    alloc_wdata.cnt = 'd1;
  end

  // ready counter write (update at cycle 3)
  generate
    for (i = 0; i < NUM_WAY; i++) begin : WAY_WREN_GEN
      assign way_wren[i] = valid_d1
                         ? (alloc_any_d1 ? (i[$clog2(NUM_WAY)-1:0] == alloc_way_enc_d1)
                                         : hit_any_d1   ? (i[$clog2(NUM_WAY)-1:0] == hit_way_enc_d1)
                                                       : (i[$clog2(NUM_WAY)-1:0] == evict_way_enc_d1))
                         : 1'b0;
    end
  endgenerate

  assign way_wdata = hit_any_d1 ? hit_wdata : alloc_wdata; // evict wdata == alloc_wdata

  /*************** Hot detection ***************/
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hot_valid <= 1'b0;
      hot_addr  <= '0;
      hot_cnt   <= '0;
    end
    else if (epoch) begin
      hot_valid <= 1'b0;
      hot_addr  <= '0;
      hot_cnt   <= '0;
    end
    else if (valid_d1) begin
      hot_valid <= 1'b0;
      if (hit_any_d1) begin
        if (way_rdata_d1[hit_way_enc_d1].cnt >= hot_threshold[CNT_SIZE-1:0] - 1) begin
          hot_valid <= 1'b1;
          hot_addr  <= addr_d1;      // (safer) aligns with valid_d1 pipeline
          hot_cnt   <= hit_wdata.cnt;
        end
        else begin
          hot_valid <= 1'b0;
          hot_addr  <= '0;
          hot_cnt   <= '0;
        end
      end
    end
    else begin
      hot_valid <= 1'b0;
    end
  end

  /*************** Valid-bit table ***************/
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < NUM_SET; s++) begin
        for (int w = 0; w < NUM_WAY; w++) begin
          way_valid[s][w] <= 1'b0;
        end
      end
    end
    else if (epoch) begin
      for (int s = 0; s < NUM_SET; s++) begin
        for (int w = 0; w < NUM_WAY; w++) begin
          way_valid[s][w] <= 1'b0;
        end
      end
    end
    else if (valid_d1) begin
      // hit
      if (hit_any_d1) begin
        if (way_rdata_d1[hit_way_enc_d1].cnt >= hot_threshold[CNT_SIZE-1:0] - 1) begin
          way_valid[addr_index_d1][hit_way_enc_d1] <= 1'b0;
        end
        else begin
          way_valid[addr_index_d1][hit_way_enc_d1] <= 1'b1;
        end
      end
      // allocate
      else if (alloc_any_d1) begin
        way_valid[addr_index_d1][alloc_way_enc_d1] <= 1'b1;
      end
    end
  end

  assign output_valid = hot_valid;
  assign output_addr  = hot_addr;
  assign output_cnt   = hot_cnt;

  /*************** Cycle 3: BRAM write & next read cycle 1 ***************/
  /*************** Module, IP Instance ***************/
  generate
    for (i = 0; i < NUM_WAY; i++) begin : BRAM_inst
      port_2_ram bram_0 (
        .data       (way_wdata),
        .q          (way_output[i]),
        .wraddress  (addr_index),
        .rdaddress  (input_addr_index),
        .wren       (way_wren[i]),
        .clock      (clk)
      );
    end
  endgenerate

endmodule

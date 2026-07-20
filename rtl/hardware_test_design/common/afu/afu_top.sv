// (C) 2001-2024 Intel Corporation. All rights reserved.
// Your use of Intel Corporation's design tools, logic functions and other 
// software and tools, and its AMPP partner logic functions, and any output 
// files from any of the foregoing (including device programming or simulation 
// files), and any associated documentation or information are expressly subject 
// to the terms and conditions of the Intel Program License Subscription 
// Agreement, Intel FPGA IP License Agreement, or other applicable 
// license agreement, including, without limitation, that your use is for the 
// sole purpose of programming logic devices manufactured by Intel and sold by 
// Intel or its authorized distributors.  Please refer to the applicable 
// agreement for further details.


// Copyright 2023 Intel Corporation.
//
// THIS SOFTWARE MAY CONTAIN PREPRODUCTION CODE AND IS PROVIDED BY THE
// COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
// WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
// BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
// WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
// OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
// EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
///////////////////////////////////////////////////////////////////////

`ifndef vivado
`include "cxl_type2_defines.svh.iv"
`else
`include "cxl_type2_defines.svh"
`endif

import ed_cxlip_top_pkg::*;
import ed_mc_axi_if_pkg::*;

module afu_top
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
  parameter SAMPLING_RATE  = 1  // Changed to 1: Sample every access (testing)
)
(

      input  logic                                             afu_clk,
      input  logic                                             afu_rstn,

      // CHMU tracker interface
      input                            chmu_query_en,
      input                            chmu_counter_mode,
      output                           chmu_query_ready,
      output                           chmu_mig_addr_cnt_en,
      output [DATA_SIZE+CNT_SIZE-1:0]  chmu_mig_addr_cnt,
      input                            chmu_mig_addr_cnt_ready,
      output                           chmu_mem_chan_rd_en,
      input  [ADDR_SIZE-1:0]           chmu_csr_addr_ub,
      input  [ADDR_SIZE-1:0]           chmu_csr_addr_lb,
      input  [11:0]                    chmu_hot_threshold,  // Dynamic hot threshold from CSR[25]

      // CHMU Debug signals for CSR visibility
      output logic [63:0]              chmu_debug_axi_status,
      output logic [63:0]              chmu_debug_fifo_status,
      output logic [63:0]              chmu_debug_state_status,
      output logic [63:0]              chmu_debug_counter_status,
      output logic [63:0]              chmu_debug_hotlist_status,

     // April 2023 - Supporting out of order responses with AXI4
      input  ed_mc_axi_if_pkg::t_to_mc_axi4    [MC_CHANNEL-1:0] cxlip2iafu_to_mc_axi4,
      output ed_mc_axi_if_pkg::t_to_mc_axi4    [MC_CHANNEL-1:0] iafu2mc_to_mc_axi4 ,
      input  ed_mc_axi_if_pkg::t_from_mc_axi4  [MC_CHANNEL-1:0] mc2iafu_from_mc_axi4,
      output ed_mc_axi_if_pkg::t_from_mc_axi4  [MC_CHANNEL-1:0] iafu2cxlip_from_mc_axi4

);

localparam MC_CHANNEL_LOCAL = 0;  // CHMU monitors first channel (index 0)

// Passthrough all AXI channels (CHMU is a passive monitor, doesn't modify signals)
assign iafu2mc_to_mc_axi4      = cxlip2iafu_to_mc_axi4;
assign iafu2cxlip_from_mc_axi4 = mc2iafu_from_mc_axi4;

// CHMU wrapper instantiation
chmu_wrapper
#(
  // common parameter
  .ADDR_SIZE(ADDR_SIZE),
  .DATA_SIZE(DATA_SIZE),

  // CHMU parameter
  .INDEX_SIZE(INDEX_SIZE),
  .NUM_WAY(NUM_WAY),
  .TAG_SIZE(TAG_SIZE),
  .CNT_SIZE(CNT_SIZE),
  .HOT_TH(HOT_TH),
  .LIST_SIZE(LIST_SIZE),
  .SAMPLING_RATE(SAMPLING_RATE)
)
u_chmu_wrapper
(
  .clk                      (afu_clk),
  .rstn                     (afu_rstn),

  .cxlip2iafu_to_mc_axi4    (cxlip2iafu_to_mc_axi4[MC_CHANNEL_LOCAL]),
  .mc2iafu_from_mc_axi4     (mc2iafu_from_mc_axi4[MC_CHANNEL_LOCAL]),

  // CHMU tracker interface
  .query_en                 (chmu_query_en),
  .counter_mode             (chmu_counter_mode),
  .query_ready              (chmu_query_ready),

  .mig_addr_cnt_en          (chmu_mig_addr_cnt_en),
  .mig_addr_cnt             (chmu_mig_addr_cnt),
  .mig_addr_cnt_ready       (chmu_mig_addr_cnt_ready),
  .mem_chan_rd_en           (chmu_mem_chan_rd_en),

  .csr_addr_ub              (chmu_csr_addr_ub),
  .csr_addr_lb              (chmu_csr_addr_lb),
  .hot_threshold            (chmu_hot_threshold),

  // Debug signal connections
  .debug_axi_status         (chmu_debug_axi_status),
  .debug_fifo_status        (chmu_debug_fifo_status),
  .debug_state_status       (chmu_debug_state_status),
  .debug_counter_status     (chmu_debug_counter_status),
  .debug_hotlist_status     (chmu_debug_hotlist_status)
);

// Note: CHMU is a passive monitor and doesn't modify AXI signals
// All AXI channels are passed through unchanged via assignments above

endmodule
`ifdef QUESTA_INTEL_OEM
`pragma questa_oem_00 "POizRfZBu2Za2e25gOrjvm1fIPLBk0eZmyFcDIFazcJl7PX67tT/saAlNoEXLHgw5mDQeEFh0JzMQ+qx/C0+PVE6a6spr5K6BpvxdLuS075hXOTsVE7Wc/lebFBxsNWYC7WKZkRFLi9LEIJIuDzdBuFqpnd6KNxaDlPfUh7jN8WMLzEL3yixxC+CcpZ1nL96FjsMR9I8wgkeME02AXMssvm/ZFxRfH2JRVTb/5Z7jzDsL2WpgVfQCjjHJ6iHMXgtMukpclk89l2S7mS02ZKKST94bLCO2ECwg+Qx3EKTSDKbEjLPA4iRDxcG0cx9Lm6nvljWvXWNQUxcJX5cGnR3yu0fadxCvEy/bsyJ37AQeJOTGRkhql/aCDLyCb+nZtjXCNJecS5+hX0J7UXt0aPP/5Coe4GPyIL3o13OhlUy9gnw5MMa+KXm8MoygZ9Ho+GazWtkKEhqZwR9t+9defkCmebYc0ra7/3ttH5Z4Fj7vf3vDtnGK93QnK/PLVJ3ZZqVFSvV9ddXOLiBNjNdlRglX/IE8WbqJFxGUGmUnfIm7+rfGGaHeE8STkXd+Q4OWFhGPi+7+suo1KZb0vEV45VSoWGAIkdwmMewkV6KrNqUPte75hX/Az3mhdMe/xsF8Vn/6k7CsLAxiFJrRFfEEl9JGj3aUG8PTkBg9QdhrfUBCCwIuP+ru3tHaiL7/zG3HYc2K1jnmaxgtdHxGYJ+BV/bOoO0oIUw4qSNlSQiyYaJDAgkvOeAxnlWNGol76gAwWvaVQIxlA+dD7epTUECBThTwpVRQD2b+urfoi7KmamtJ0AVQY4szoiXghLRPt/jJeIYozC/3CS6PfLYQRF0DWqLy0qV5XjFpgIbp9ciRtdgFvm5T1NZfX0hHmRqDBVahGpPCtwF7CIQ3BXw4yWF5Ib0NsPQsxpbQa65b4h5e8eSmcWGeOfQHWHWs526rgAHJtGht+TVaUDB941HR7l8hkGYKJn3qrDIABM3KG4zM5hN2PRlsGy+wpiC3cWlxctnww5f"
`endif

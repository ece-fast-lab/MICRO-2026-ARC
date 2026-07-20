module sampling_module #(
  parameter ADDR_SIZE      = 21,
  parameter SAMPLING_RATE  = 1
)(
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic [ADDR_SIZE-1:0]  input_addr,
  input  logic                  input_addr_valid,
  input  logic                  epoch,
  
  output logic [ADDR_SIZE-1:0]  output_addr,
  output logic                  output_addr_valid
);

  localparam RATE_WIDTH = (SAMPLING_RATE <= 1) ? 1 : $clog2(SAMPLING_RATE);
  logic [RATE_WIDTH-1:0] sampling_cnt;
  logic [ADDR_SIZE-1:0]  addr;
  
  /*************** state transition  ***************/
  logic [1:0]                  state, next_state;
  localparam STATE_IDLE  				= 2'd0;
  localparam STATE_REQ_1  			= 2'd1;
  localparam STATE_REQ_2        = 2'd2;
  localparam STATE_EPOCH        = 2'd3;
  
  always_comb begin
    next_state = STATE_IDLE;
    case(state)
      STATE_IDLE: begin
        if (epoch) begin
          next_state = STATE_EPOCH;
        end
        else if (input_addr_valid) begin
          next_state = STATE_REQ_1;
        end
      end
      STATE_REQ_1: begin
        if (epoch) begin
          next_state = STATE_EPOCH;
        end
        else begin
          next_state = STATE_REQ_2;
        end
      end
      STATE_REQ_2: begin 
        if (epoch) begin
          next_state = STATE_EPOCH;
        end
        else if (input_addr_valid) begin
          next_state = STATE_REQ_1;
        end        
      end   
      STATE_EPOCH: begin 
        if (epoch) begin
          next_state = STATE_EPOCH;
        end
        else if (input_addr_valid) begin
          next_state = STATE_REQ_1;
        end
      end
      default:;
    endcase 
  end

  always_ff @ (posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= 2'b0;
    end
    else begin
      state <= next_state;
    end
  end
  
  
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      addr <= {ADDR_SIZE{1'b0}};
    end 
    else if (next_state == STATE_REQ_1) begin
      addr <= input_addr;
    end
  end

  /*************** sampling_cnt increment ***************/ 
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sampling_cnt <= {RATE_WIDTH{1'b0}};
    end 
    else begin
      if (state == STATE_REQ_1) begin
        if (SAMPLING_RATE == 1) begin
          sampling_cnt <= 1'b0;
        end 
        else if (sampling_cnt == SAMPLING_RATE-1) begin
          sampling_cnt <= '0;
        end 
        else begin
          sampling_cnt <= sampling_cnt + 1'b1;
        end
      end
    end
  end

  /*************** sampling logic ***************/ 
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      output_addr_valid <= 1'b0;
      output_addr  <= '0;
    end 
    else begin
      if (state == STATE_REQ_2) begin
        if (sampling_cnt == '0) begin
          output_addr_valid <= 1'b1;
          output_addr <= addr;
        end
      end
      else begin
        output_addr_valid <= 1'b0;
      end
    end
  end
endmodule

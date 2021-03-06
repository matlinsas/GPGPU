// 
// Copyright 2012-2013 Jeff Bush
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
// 

// XXX there is no way currently to recover if there is an under-run.

module vga_controller(
	input 					clk,
	input					reset,

	// To DAC
	output [7:0]			vga_r,
	output [7:0]			vga_g,
	output [7:0]			vga_b,
	output 					vga_clk,
	output 					vga_blank_n,
	output 					vga_hs,
	output 					vga_vs,
	output 					vga_sync_n,
	
	// To AXI interconnect
	output [31:0]			axi_araddr,
	output [7:0]			axi_arlen,
	output 					axi_arvalid,
	input					axi_arready,
	output 					axi_rready, 
	input					axi_rvalid,         
	input [31:0]			axi_rdata);

	localparam TOTAL_PIXELS = 640 * 480;
	localparam BURST_LENGTH = 64;
	localparam PIXEL_FIFO_LENGTH = 128;
	localparam DEFAULT_FB_ADDR = 32'h10000000;

	/*AUTOWIRE*/
	// Beginning of automatic wires (for undeclared instantiated-module outputs)
	wire		in_visible_region;	// From timing_generator of vga_timing_generator.v
	wire		new_frame;		// From timing_generator of vga_timing_generator.v
	wire		pixel_enable;		// From timing_generator of vga_timing_generator.v
	// End of automatics
	reg [31:0] vram_addr;
	wire[7:0] _ignore_alpha;
	wire pixel_fifo_empty;
	wire pixel_fifo_almost_empty;
	reg[31:0] fb_base_address;
	reg[1:0] axi_state;
	reg[7:0] burst_count;
	reg[18:0] pixel_count;

	assign vga_blank_n = in_visible_region;
	assign vga_sync_n = 1'b0;	// Not used
	assign vga_clk = pixel_enable;	// This is a bid odd: using enable as external clock.

	// Buffers data to the display from SDRAM.  The enqueue threshold
	// is 8 to ensure this can accept an entire burst from memory.
	sync_fifo #(
		.DATA_WIDTH(32), 
		.NUM_ENTRIES(PIXEL_FIFO_LENGTH), 
		.ALMOST_EMPTY_THRESHOLD(PIXEL_FIFO_LENGTH - BURST_LENGTH - 1)) pixel_fifo(
		.clk(clk),
		.reset(reset),
		.flush_i(new_frame),
		.empty_o(pixel_fifo_empty),
		.almost_empty_o(pixel_fifo_almost_empty),
		.value_o({vga_r, vga_g, vga_b, _ignore_alpha}),
		.value_i(axi_rdata),
		.enqueue_i(axi_rvalid),
		.full_o(),
		.dequeue_i(pixel_enable && in_visible_region && !pixel_fifo_empty));

	assert_false #("Pixel FIFO Underrun") a0(
		.clk(clk),
		.test(pixel_enable && in_visible_region && pixel_fifo_empty));

	localparam STATE_WAIT_FRAME_START = 0;
	localparam STATE_WAIT_FIFO_EMPTY = 1;
	localparam STATE_ISSUE_ADDR = 2;
	localparam STATE_BURST_ACTIVE = 3;
		
	always @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			fb_base_address <= DEFAULT_FB_ADDR;
			vram_addr <= DEFAULT_FB_ADDR;
			axi_state <= STATE_WAIT_FRAME_START;
			
			/*AUTORESET*/
			// Beginning of autoreset for uninitialized flops
			burst_count <= 8'h0;
			pixel_count <= 19'h0;
			// End of automatics
		end
		else 
		begin
			case (axi_state)
				STATE_WAIT_FRAME_START:
				begin
					// Since we know the FIFO will be flushed with the new
					// frame, we can skip STATE_WAIT_FIFO_EMPTY.
					if (new_frame)
					begin
						axi_state <= STATE_ISSUE_ADDR;
						pixel_count <= 0;
						vram_addr <= fb_base_address;
					end
				end

				STATE_WAIT_FIFO_EMPTY:
				begin
					if (pixel_fifo_almost_empty)
						axi_state <= STATE_ISSUE_ADDR;
				end

				STATE_ISSUE_ADDR:
				begin
					if (axi_arready)
						axi_state <= STATE_BURST_ACTIVE;				
				end

				STATE_BURST_ACTIVE:
				begin
					if (axi_rvalid)
					begin
						if (burst_count == BURST_LENGTH - 1)
						begin
							burst_count <= 0;
							if (pixel_count == TOTAL_PIXELS - BURST_LENGTH)
								axi_state <= STATE_WAIT_FRAME_START;
							else
							begin
								if (pixel_fifo_almost_empty)
									axi_state <= STATE_ISSUE_ADDR;
								else
									axi_state <= STATE_WAIT_FIFO_EMPTY;
								
								vram_addr <= vram_addr + BURST_LENGTH * 4;
								pixel_count <= pixel_count + BURST_LENGTH;
							end
						end	
						else
							burst_count <= burst_count + 1;
					end
				end

				default: axi_state <= STATE_WAIT_FRAME_START;
			endcase
		end
	end
	
	assign axi_rready = 1'b1;	// We always have enough room when a request is made.
	assign axi_arlen = BURST_LENGTH;
	assign axi_arvalid = axi_state == STATE_ISSUE_ADDR;
	assign axi_araddr = vram_addr;

	vga_timing_generator timing_generator(
		/*AUTOINST*/
					      // Outputs
					      .vga_vs		(vga_vs),
					      .vga_hs		(vga_hs),
					      .in_visible_region(in_visible_region),
					      .pixel_enable	(pixel_enable),
					      .new_frame	(new_frame),
					      // Inputs
					      .clk		(clk),
					      .reset		(reset));
endmodule

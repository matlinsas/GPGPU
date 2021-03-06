// 
// Copyright 2011-2012 Jeff Bush
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

`include "defines.v"

//
// Strand finite state machine. 
//
// This tracks the state of a single strand.  It will keep track of cache misses 
// and restart a strand when it receives updates from the L1 cache.
//
// This also handles delaying strands when there are RAW/WAW conflicts (because of 
// memory loads or long latency instructions). Currently, we don't detect these 
// conflicts explicitly but always delay the next instruction when one of these
// instructions that could generate a RAW is issued.
//
// There are three types of rollbacks, which are encoded as follows:
//
// +------------------------+-------------+------------+----------+
// | Type                   | rollback_i  |  suspend_i | retry_i  |
// +------------------------+-------------+------------+----------+
// | mispredicted branch    |       1     |      0     |    0     |
// | retry                  |       1     |      0     |    1     |
// | dcache miss/stbuf full |       1     |      1     |    0     |
// +------------------------+-------------+------------+----------+
//
// A retry occurs when a cache fill completes in the same cycle that a 
// cache miss occurs for the same line.  We don't suspend the strand because
// the miss is satisfied, but we need to restart it to pick up the data.
//

module strand_fsm(
	input					clk,
	input					reset,

	// To/From instruction fetch stage
	output					next_instr_request,
	input					instruction_valid_i,	// instruction_i is valid
	input [31:0]			instruction_i,
	input					long_latency,
	
	// From strand select stage
	output					ready,
	input					issue, // we have permission to issue (based on ready, watch for loop)

	// To decode stage
	output [3:0]			reg_lane_select_o,
	output [31:0]			strided_offset_o,

	// From downstream execution units.  Signals to suspend/resume strand.
	input					rollback_i,
	input					suspend_i,
	input					retry_i,
	input					resume_i,
	input [31:0]			rollback_strided_offset_i,
	input [3:0]				rollback_reg_lane_i,
	
	// Performance counter events
	output					pc_event_raw_wait,
	output					pc_event_dcache_wait,
	output					pc_event_icache_wait);

	assert_false #("simultaneous resume and suspend") a0(
		.clk(clk),
		.test(rollback_i && resume_i));
	assert_false #("simultaneous suspend and retry") a1(
		.clk(clk),
		.test(rollback_i && suspend_i && retry_i));
	assert_false #("retry/suspend without rollback") a2(
		.clk(clk),
		.test(!rollback_i && (suspend_i || retry_i)));

	localparam STATE_READY = 0;
	localparam STATE_VECTOR_LOAD = 1;
	localparam STATE_VECTOR_STORE = 2;
	localparam STATE_RAW_WAIT = 3;
	localparam STATE_CACHE_WAIT = 4;

	reg[3:0] load_delay_ff;
	reg[3:0] load_delay_nxt;
	reg[2:0] thread_state_ff;
	reg[2:0] thread_state_nxt;
	reg[31:0] strided_offset_nxt;
	reg[3:0] reg_lane_select_ff ;
	reg[3:0] reg_lane_select_nxt;
	reg[31:0] strided_offset_ff; 

	wire is_fmt_c = instruction_i[31:30] == 2'b10;
	wire[3:0] c_op_type = instruction_i[28:25];
	wire is_load = instruction_i[29]; // Assumes fmt c
	wire is_synchronized_store = !is_load && c_op_type == `MEM_SYNC;	// assumes fmt c
	wire is_multi_cycle_transfer = is_fmt_c 
		&& (c_op_type == `MEM_STRIDED
		|| c_op_type == `MEM_STRIDED_M
		|| c_op_type == `MEM_STRIDED_IM
		|| c_op_type == `MEM_SCGATH
		|| c_op_type == `MEM_SCGATH_M
		|| c_op_type == `MEM_SCGATH_IM);
	wire is_masked = (c_op_type == `MEM_STRIDED_M
		|| c_op_type == `MEM_STRIDED_IM
		|| c_op_type == `MEM_SCGATH_M
		|| c_op_type == `MEM_SCGATH_IM
		|| c_op_type == `MEM_BLOCK_M
		|| c_op_type == `MEM_BLOCK_IM);
		
	wire vector_transfer_end = reg_lane_select_ff == 0 && thread_state_ff != STATE_CACHE_WAIT;
	wire is_vector_transfer = thread_state_ff == STATE_VECTOR_LOAD || thread_state_ff == STATE_VECTOR_STORE
	   || is_multi_cycle_transfer;
	assign next_instr_request = ((thread_state_ff == STATE_READY 
		&& !is_multi_cycle_transfer)
		|| (is_vector_transfer && vector_transfer_end)) && issue;
	wire will_issue = instruction_valid_i && issue;
	assign ready = thread_state_ff != STATE_RAW_WAIT
		&& thread_state_ff != STATE_CACHE_WAIT
		&& instruction_valid_i
		&& !rollback_i;

	// When a load occurs, there is a potential RAW dependency.  We just insert nops 
	// to cover that.  A more efficient implementation could detect when a true 
	// dependency exists.
	always @*
	begin
		if (thread_state_ff == STATE_RAW_WAIT)
			load_delay_nxt = load_delay_ff - 1;
		else 
			load_delay_nxt = 3; 
	end
	
	always @*
	begin
		if (suspend_i || retry_i)
		begin
			reg_lane_select_nxt = rollback_reg_lane_i;
			strided_offset_nxt = rollback_strided_offset_i;
		end
		else if (rollback_i || (vector_transfer_end && will_issue))
		begin
			reg_lane_select_nxt = 4'd15;
			strided_offset_nxt = 0;
		end
		else if (((thread_state_ff == STATE_VECTOR_LOAD || thread_state_ff == STATE_VECTOR_STORE)
		  || is_multi_cycle_transfer) 
		  && thread_state_ff != STATE_CACHE_WAIT
		  && thread_state_ff != STATE_RAW_WAIT
		  && will_issue)
		begin
			reg_lane_select_nxt = reg_lane_select_ff - 1;
			strided_offset_nxt = strided_offset_ff + (is_masked 
				? { instruction_i[24:15], 2'b00 }
				: { instruction_i[24:10], 2'b00 });
		end
		else
		begin
			reg_lane_select_nxt = reg_lane_select_ff;
			strided_offset_nxt = strided_offset_ff;
		end
	end

	always @*
	begin
		if (rollback_i)
		begin
			if (suspend_i)
				thread_state_nxt = STATE_CACHE_WAIT;
			else
				thread_state_nxt = STATE_READY;
		end
		else
		begin
			thread_state_nxt = thread_state_ff;
		
			case (thread_state_ff)
				STATE_READY:
				begin
					// Only update state machine if this is a valid instruction
					if (will_issue && is_fmt_c)
					begin
						// Memory transfer
						if (is_multi_cycle_transfer && !vector_transfer_end)
						begin
							// Vector transfer
							if (is_load)
								thread_state_nxt = STATE_VECTOR_LOAD;
							else
								thread_state_nxt = STATE_VECTOR_STORE;
						end
						else if (is_load || is_synchronized_store)
							thread_state_nxt = STATE_RAW_WAIT;	
					end
					else if (long_latency && will_issue)
						thread_state_nxt = STATE_RAW_WAIT;	// long latency instruction
				end
				
				STATE_VECTOR_LOAD:
				begin
					if (vector_transfer_end)
						thread_state_nxt = STATE_RAW_WAIT;
				end
				
				STATE_VECTOR_STORE:
				begin
					if (vector_transfer_end)
						thread_state_nxt = STATE_READY;
				end
				
				STATE_RAW_WAIT:
				begin
					if (load_delay_ff == 1)
						thread_state_nxt = STATE_READY;
				end
				
				STATE_CACHE_WAIT:
				begin
					if (resume_i)
						thread_state_nxt = STATE_READY;
				end
			endcase
		end
	end

	assert_false #("resume request for strand that is not waiting") a4(
		.clk(clk),
		.test(thread_state_ff != STATE_CACHE_WAIT && resume_i));
	
	assign reg_lane_select_o = reg_lane_select_ff;
	assign strided_offset_o = strided_offset_ff;
	

	assign pc_event_raw_wait = thread_state_ff == STATE_RAW_WAIT;
	assign pc_event_dcache_wait = thread_state_ff == STATE_CACHE_WAIT;
	assign pc_event_icache_wait = !pc_event_raw_wait
		&& !pc_event_dcache_wait && !instruction_valid_i;

	always @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			reg_lane_select_ff <= 4'd15;

			/*AUTORESET*/
			// Beginning of autoreset for uninitialized flops
			load_delay_ff <= 4'h0;
			strided_offset_ff <= 32'h0;
			thread_state_ff <= 3'h0;
			// End of automatics
		end
		else
		begin
			if (rollback_i)
				load_delay_ff				<= 0;
			else
				load_delay_ff				<= load_delay_nxt;
	
			thread_state_ff					<= thread_state_nxt;
			reg_lane_select_ff				<= reg_lane_select_nxt;
			strided_offset_ff				<= strided_offset_nxt;
		end
	end
endmodule

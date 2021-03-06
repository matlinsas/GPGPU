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

//
// Stage 3 of floating point addition pipeline
// - Add significands
// - Convert result back to signed magnitude form
// 

module fp_adder_stage3
	#(parameter EXPONENT_WIDTH = 8, 
	parameter SIGNIFICAND_WIDTH = 23,
	parameter SFP_WIDTH = 1 + EXPONENT_WIDTH + SIGNIFICAND_WIDTH)

	(input									clk,
	input									reset,
	input[SIGNIFICAND_WIDTH + 2:0] 			add2_significand1,
	input[SIGNIFICAND_WIDTH + 2:0] 			add2_significand2,
	output reg[SIGNIFICAND_WIDTH + 2:0] 	add3_significand,
	output reg 								add3_sign,
	input [EXPONENT_WIDTH - 1:0] 			add2_exponent, 
	output reg[EXPONENT_WIDTH - 1:0] 		add3_exponent);

	reg[SIGNIFICAND_WIDTH + 2:0] 			significand_nxt;
	reg 									sign_nxt;

	// Add
	wire[SIGNIFICAND_WIDTH + 2:0] sum = add2_significand1 + add2_significand2;

	// Convert back to signed magnitude
	always @*
	begin
		if (sum[SIGNIFICAND_WIDTH + 2])
		begin
			significand_nxt = ~sum + 1;	
			sign_nxt = 1;
		end
		else
		begin
			significand_nxt = sum;
			sign_nxt = 0;
		end
	end
	
	always @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			/*AUTORESET*/
			// Beginning of autoreset for uninitialized flops
			add3_exponent <= {EXPONENT_WIDTH{1'b0}};
			add3_sign <= 1'h0;
			add3_significand <= {(1+(SIGNIFICAND_WIDTH+2)){1'b0}};
			// End of automatics
		end
		else
		begin
			add3_exponent 				<= add2_exponent;
			add3_sign					<= sign_nxt;
			add3_significand			<= significand_nxt;
		end
	end	
endmodule

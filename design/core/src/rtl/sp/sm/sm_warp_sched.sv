// Round-robin candidate selection for the SM issue controller. This is an
// arbitration decision, not an externally stalled instruction packet: the
// controller captures a selected instruction into its own dispatch register.
module sm_warp_sched #(
  parameter int WARPS=64
) (
  input logic clk,rst_n,
  input logic [WARPS-1:0] eligible,
  input logic take,
  output logic valid,
  output logic [5:0] selected
);
  logic [5:0] next_priority;
  initial begin
    if(WARPS<1 || WARPS>64)$fatal(1,"sm_warp_sched WARPS must be 1..64");
  end
  always_comb begin
    valid=0;
    selected=0;
    for(int offset=0;offset<WARPS;offset++)begin
      int candidate;
      candidate=int'(next_priority)+offset;
      if(candidate>=WARPS)candidate=candidate-WARPS;
      if(rst_n && !valid && eligible[candidate])begin
        valid=1;
        selected=6'(candidate);
      end
    end
  end
  always_ff @(posedge clk or negedge rst_n)begin
    if(!rst_n)next_priority<=0;
    else if(take && valid)
      next_priority<=int'(selected)==WARPS-1 ? 6'd0 : selected+6'd1;
  end
`ifdef SM_ASSERTIONS
  a_take_requires_candidate: assert property(@(posedge clk)disable iff(!rst_n)take |-> valid);
  a_selected_is_eligible: assert property(@(posedge clk)disable iff(!rst_n)
    valid |-> int'(selected)<WARPS && eligible[int'(selected)]);
`endif
endmodule

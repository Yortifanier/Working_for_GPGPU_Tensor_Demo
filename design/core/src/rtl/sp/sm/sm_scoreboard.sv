// Conservative per-warp register dependencies with full operation identities.
// A reserved instruction owns its destinations and uncaptured sources before
// backend dispatch. Completion is accepted independently of warp scheduling.
module sm_scoreboard #(
  parameter int WARPS=64,
  parameter int FLIGHTS=16
) (
  input logic clk,rst_n,
  input sm_pkg::sm_issue_t probe[WARPS],
  output logic [WARPS-1:0] probe_ready,
  input logic reserve_valid,
  output logic reserve_ready,
  input sm_pkg::sm_issue_t reserve,
  input logic dispatch_valid,
  input sm_pkg::sm_token_t dispatch_token,
  input logic source_valid,
  output logic source_ready,
  input sm_pkg::sm_token_t source_token,
  input logic complete_valid,
  output logic complete_ready,
  input sm_pkg::sm_complete_t complete,
  output logic retire_valid,
  output sm_pkg::sm_token_t retire_token,
  output sm_pkg::sm_status_e retire_status,
  output logic protocol_error,
  output logic [WARPS-1:0] warp_busy
);
  import sm_pkg::*;
  localparam int WARP_W=WARPS<=1 ? 1 : $clog2(WARPS);
  logic [FLIGHTS-1:0] live,dispatched,source_done;
  sm_token_t tokens[FLIGHTS];
  sm_reg_mask_t sources[FLIGHTS],destinations[FLIGHTS];
  integer free_slot,dispatch_slot,source_slot,complete_slot;
  logic dispatch_good,source_good,complete_good,complete_status_valid;

  initial begin
    if(WARPS<1 || WARPS>SM_MAX_WARPS || FLIGHTS<1)
      $fatal(1,"Invalid sm_scoreboard parameters");
  end

  function automatic logic eligible(input sm_issue_t request);
    sm_reg_mask_t src,dst;
    if(32'(request.token.warp)>=WARPS || !spans_valid(request.instr)) return 0;
    src=source_mask(request.instr);dst=destination_mask(request.instr);
    for(int f=0;f<FLIGHTS;f++) if(live[f]) begin
      if(tokens[f]==request.token) return 0;
      if(tokens[f].warp==request.token.warp) begin
        // A live warp slot cannot silently change owner/epoch while old
        // register responsibilities still refer to that slot.
        if(tokens[f].owner!=request.token.owner ||
           tokens[f].generation!=request.token.generation ||
           tokens[f].epoch!=request.token.epoch) return 0;
        if((src & destinations[f])!='0 || (dst & destinations[f])!='0 ||
           (!source_done[f] && (dst & sources[f])!='0)) return 0;
      end
    end
    return 1;
  endfunction

  // Keep state-only outputs separate from candidate-dependent readiness. A
  // scheduler may use warp_busy to construct the next probe/reserve candidate.
  always_comb begin
    warp_busy='0;
    for(int f=0;f<FLIGHTS;f++) if(live[f])
      warp_busy[WARP_W'(tokens[f].warp)]=1;
  end
  always_comb begin
    free_slot=-1;dispatch_slot=-1;source_slot=-1;complete_slot=-1;
    for(int f=0;f<FLIGHTS;f++) begin
      if(!live[f] && free_slot<0) free_slot=f;
      if(live[f]) begin
        if(tokens[f]==dispatch_token) dispatch_slot=f;
        if(tokens[f]==source_token) source_slot=f;
        if(tokens[f]==complete.token) complete_slot=f;
      end
    end
  end
  for(genvar w=0;w<WARPS;w++) begin:g_probe
    assign probe_ready[w]=rst_n && free_slot>=0 && eligible(probe[w]);
  end
  assign reserve_ready=rst_n && free_slot>=0 && eligible(reserve);
  assign source_ready=rst_n;
  assign complete_ready=rst_n;
  always_comb begin
    dispatch_good=dispatch_slot>=0 && !dispatched[dispatch_slot];
    source_good=source_slot>=0 && !source_done[source_slot] &&
      (dispatched[source_slot] ||
       (dispatch_valid && dispatch_good && dispatch_slot==source_slot));
    complete_status_valid=complete.status inside {SM_OK,SM_BAD_WARP,SM_BAD_CONTEXT,
      SM_BUSY,SM_BAD_IR,SM_UNSUPPORTED,SM_SEQUENCE_EXHAUSTED,SM_EXEC_ERROR,SM_PROTOCOL};
    complete_good=complete_slot>=0 && complete_status_valid &&
      (dispatched[complete_slot] ||
       (dispatch_valid && dispatch_good && dispatch_slot==complete_slot)) &&
      (complete.status!=SM_OK || destinations[complete_slot]=='0 || complete.writes_committed);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      live<='0;dispatched<='0;source_done<='0;
      retire_valid<=0;retire_token<='0;retire_status<=SM_OK;protocol_error<=0;
      for(int f=0;f<FLIGHTS;f++) begin
        tokens[f]<='0;sources[f]<='0;destinations[f]<='0;
      end
    end else begin
      retire_valid<=0;protocol_error<=0;
      if(reserve_valid && reserve_ready) begin
        live[free_slot]<=1;dispatched[free_slot]<=0;source_done[free_slot]<=0;
        tokens[free_slot]<=reserve.token;
        sources[free_slot]<=source_mask(reserve.instr);
        destinations[free_slot]<=destination_mask(reserve.instr);
      end
      if(dispatch_valid) begin
        if(dispatch_good) dispatched[dispatch_slot]<=1;
        else protocol_error<=1;
      end
      if(source_valid && source_ready &&
          !(complete_valid && complete_ready && complete_good && source_slot==complete_slot)) begin
        if(source_good) source_done[source_slot]<=1;
        else protocol_error<=1;
      end
      if(complete_valid && complete_ready) begin
        if(complete_good) begin
          live[complete_slot]<=0;
          retire_valid<=1;retire_token<=complete.token;retire_status<=complete.status;
        end else protocol_error<=1;
      end
    end
  end
`ifdef SM_ASSERTIONS
  for(genvar f=0;f<FLIGHTS;f++) begin:g_flight_assert
    assert property(@(posedge clk) disable iff(!rst_n)
      live[f] |-> 32'(tokens[f].warp)<WARPS);
    for(genvar g=f+1;g<FLIGHTS;g++) begin:g_unique
      assert property(@(posedge clk) disable iff(!rst_n)
        !(live[f] && live[g] && tokens[f]==tokens[g]));
    end
  end
`endif
endmodule

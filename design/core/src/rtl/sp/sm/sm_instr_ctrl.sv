// Uniform-control project IR frontend, dependency admission and backend routing.
// Backends, RF storage, ITS, launch allocation and PTX lowering are separate.
module sm_instr_ctrl #(
  parameter int WARPS=64,
  parameter int FLIGHTS=16
)(sm_ctrl_if.dut bus);
  import sm_pkg::*;
  sm_fetch_t buffered[WARPS];
  logic [WARPS-1:0] buffered_valid,eligible,probe_ready;
  logic [2:0] owner[WARPS];
  logic [15:0] generation[WARPS],owner_history[8];
  logic [31:0] active_mask[WARPS],instance_counter[WARPS];
  logic [7:0] owner_active;
  sm_issue_t probes[WARPS],candidate,queued;
  logic queued_valid,queued_ready,selected_valid,take,selected_exec;
  logic [5:0] selected;
  logic reserve_valid,reserve_ready,protocol_error,retire_valid;
  sm_token_t retire_token;
  sm_status_e retire_status,warp_command_status,fetch_status;
  logic [31:0] ticket_counter;
  logic warp_rsp_space,fetch_rsp_space;
  integer wc,fw;

  initial begin
    if(WARPS<1 || WARPS>SM_MAX_WARPS || FLIGHTS<1)
      $fatal(1,"Invalid sm_instr_ctrl parameters");
  end
  sm_warp_sched #(.WARPS(WARPS)) scheduler(
    .clk(bus.clk),.rst_n(bus.rst_n),.eligible(eligible),.take(take),
    .valid(selected_valid),.selected(selected)
  );
  sm_scoreboard #(.WARPS(WARPS),.FLIGHTS(FLIGHTS)) scoreboard(
    .clk(bus.clk),.rst_n(bus.rst_n),.probe(probes),.probe_ready(probe_ready),
    .reserve_valid(reserve_valid),.reserve_ready(reserve_ready),.reserve(candidate),
    .dispatch_valid(queued_valid&&queued_ready),.dispatch_token(queued.token),
    .source_valid(bus.source_valid),.source_ready(bus.source_ready),.source_token(bus.source_token),
    .complete_valid(bus.complete_valid),.complete_ready(bus.complete_ready),.complete(bus.complete),
    .retire_valid(retire_valid),.retire_token(retire_token),.retire_status(retire_status),
    .protocol_error(protocol_error),.warp_busy(bus.warp_busy)
  );

  always_comb begin
    owner_active='0;
    for(int i=0;i<WARPS;i++)if(bus.warp_state[i]!=SM_W_FREE)owner_active[owner[i]]=1;
    wc=int'(bus.warp_cmd.warp);fw=int'(bus.fetch.warp);
    warp_command_status=SM_OK;
    if(bus.warp_cmd.epoch!=bus.reset_epoch)warp_command_status=SM_BAD_CONTEXT;
    else if(wc>=WARPS)warp_command_status=SM_BAD_WARP;
    else if(bus.warp_cmd.detach)begin
      if(bus.warp_state[wc]==SM_W_FREE || owner[wc]!=bus.warp_cmd.owner ||
          generation[wc]!=bus.warp_cmd.generation)warp_command_status=SM_BAD_CONTEXT;
      else if(!(bus.warp_state[wc] inside {SM_W_EXITED,SM_W_FAULT}) || bus.warp_busy[wc])
        warp_command_status=SM_BUSY;
    end else begin
      if(bus.warp_state[wc]!=SM_W_FREE)warp_command_status=SM_BUSY;
      else if(bus.warp_cmd.generation==0 || bus.warp_cmd.active_mask==0 ||
          bus.warp_cmd.entry_pc[1:0]!=0)warp_command_status=SM_BAD_CONTEXT;
      else if(owner_active[bus.warp_cmd.owner])begin
        if(owner_history[bus.warp_cmd.owner]!=bus.warp_cmd.generation)
          warp_command_status=SM_BAD_CONTEXT;
      end else if(owner_history[bus.warp_cmd.owner]==16'hffff)
        warp_command_status=SM_SEQUENCE_EXHAUSTED;
      else if(bus.warp_cmd.generation<=owner_history[bus.warp_cmd.owner])
        warp_command_status=SM_BAD_CONTEXT;
    end
    fetch_status=SM_OK;
    if(bus.fetch.epoch!=bus.reset_epoch)fetch_status=SM_BAD_CONTEXT;
    else if(fw>=WARPS)fetch_status=SM_BAD_WARP;
    else if(bus.warp_state[fw]!=SM_W_RUN || owner[fw]!=bus.fetch.owner ||
        generation[fw]!=bus.fetch.generation)fetch_status=SM_BAD_CONTEXT;
    else if(bus.fetch.pc!=bus.next_pc[fw] || bus.fetch.pc[1:0]!=0 ||
        (bus.fetch.instr.lane_mask & ~active_mask[fw])!=0 || !spans_valid(bus.fetch.instr))
      fetch_status=SM_BAD_IR;
    else if(!(bus.fetch.instr.op inside {SM_OP_EXEC,SM_OP_NOP,SM_OP_BRA,SM_OP_WAIT,SM_OP_EXIT}))
      fetch_status=SM_BAD_IR;
    else if(instance_counter[fw]==32'hffffffff)fetch_status=SM_SEQUENCE_EXHAUSTED;
    else if(bus.fetch.instr.op==SM_OP_EXEC)begin
      if(int'(bus.fetch.instr.unit_id)>=SM_EXEC_COUNT)fetch_status=SM_UNSUPPORTED;
      else if(!bus.capabilities[int'(bus.fetch.instr.unit_id)])fetch_status=SM_UNSUPPORTED;
      else if(bus.fetch.instr.unit_id==SM_EX_SALU && !bus.fetch.instr.uniform_proven)
        fetch_status=SM_BAD_IR;
      else if(ticket_counter==32'hffffffff && bus.fetch.instr.lane_mask!=0)
        fetch_status=SM_SEQUENCE_EXHAUSTED;
    end else begin
      if(source_mask(bus.fetch.instr)!='0 || destination_mask(bus.fetch.instr)!='0)
        fetch_status=SM_BAD_IR;
      if(bus.fetch.instr.op inside {SM_OP_BRA,SM_OP_WAIT,SM_OP_EXIT} &&
          bus.fetch.instr.lane_mask!=active_mask[fw])fetch_status=SM_BAD_IR;
      if(bus.fetch.instr.op==SM_OP_BRA && bus.fetch.instr.branch_target[1:0]!=0)
        fetch_status=SM_BAD_IR;
    end
    if(fetch_status==SM_OK && bus.fetch.pc==32'hfffffffc &&
        !(bus.fetch.instr.op inside {SM_OP_BRA,SM_OP_EXIT}))fetch_status=SM_SEQUENCE_EXHAUSTED;
  end
  assign warp_rsp_space=!bus.warp_rsp_valid || bus.warp_rsp_ready;
  assign fetch_rsp_space=!bus.fetch_rsp_valid || bus.fetch_rsp_ready;
  assign bus.warp_cmd_ready=bus.rst_n && warp_rsp_space;
  assign bus.fetch_ready=bus.rst_n && fetch_rsp_space &&
    (fetch_status!=SM_OK || !buffered_valid[fw]);
  always_comb begin
    bus.issue_valid='0;
    bus.issue=queued;
    queued_ready=0;
    if(queued_valid)begin
      bus.issue_valid[int'(queued.instr.unit_id)]=bus.rst_n;
      queued_ready=bus.issue_ready[int'(queued.instr.unit_id)];
    end
  end
  always_comb begin
    for(int i=0;i<WARPS;i++)begin
      probes[i]='0;
      probes[i].token.epoch=bus.reset_epoch;
      probes[i].token.ticket=ticket_counter;
      probes[i].token.owner=owner[i];probes[i].token.generation=generation[i];
      probes[i].token.warp=6'(i);probes[i].token.instance_id=instance_counter[i];
      probes[i].pc=buffered[i].pc;probes[i].instr=buffered[i].instr;
    end
  end
  always_comb begin
    for(int i=0;i<WARPS;i++)begin
      eligible[i]=bus.rst_n && buffered_valid[i] && bus.warp_state[i]==SM_W_RUN;
      if(buffered[i].instr.op==SM_OP_EXEC && buffered[i].instr.lane_mask!=0)
        eligible[i]&=probe_ready[i] && (!queued_valid || queued_ready) && ticket_counter!=32'hffffffff;
      else if(buffered[i].instr.op inside {SM_OP_BRA,SM_OP_WAIT,SM_OP_EXIT})
        eligible[i]&=!bus.warp_busy[i];
      if(retire_valid && retire_status!=SM_OK && retire_token.warp==6'(i))eligible[i]=0;
    end
  end
  assign candidate=probes[int'(selected)];
  assign selected_exec=candidate.instr.op==SM_OP_EXEC && candidate.instr.lane_mask!=0;
  assign reserve_valid=selected_valid && selected_exec && (!queued_valid || queued_ready);
  assign take=selected_valid && (!selected_exec || reserve_ready);
  always_ff @(posedge bus.clk or negedge bus.rst_n)begin
    if(!bus.rst_n)begin
      bus.warp_rsp_valid<=0;bus.warp_rsp<='0;bus.fetch_rsp_valid<=0;bus.fetch_rsp<='0;
      bus.protocol_errors<=0;buffered_valid<='0;queued_valid<=0;queued<='0;ticket_counter<=1;
      for(int o=0;o<8;o++)owner_history[o]<=0;
      for(int i=0;i<WARPS;i++)begin
        bus.warp_state[i]<=SM_W_FREE;bus.warp_fault[i]<=SM_OK;bus.next_pc[i]<=0;
        owner[i]<=0;generation[i]<=0;active_mask[i]<=0;instance_counter[i]<=1;buffered[i]<='0;
      end
    end else begin
      if(bus.warp_rsp_valid && bus.warp_rsp_ready)bus.warp_rsp_valid<=0;
      if(bus.fetch_rsp_valid && bus.fetch_rsp_ready)bus.fetch_rsp_valid<=0;
      if(queued_valid && queued_ready)queued_valid<=0;
      if(bus.warp_cmd_valid && bus.warp_cmd_ready)begin
        bus.warp_rsp_valid<=1;
        bus.warp_rsp.epoch<=bus.warp_cmd.epoch;
        bus.warp_rsp.tag<=bus.warp_cmd.tag;bus.warp_rsp.warp<=bus.warp_cmd.warp;
        bus.warp_rsp.owner<=bus.warp_cmd.owner;bus.warp_rsp.generation<=bus.warp_cmd.generation;
        bus.warp_rsp.status<=warp_command_status;
        if(warp_command_status==SM_OK)begin
          buffered_valid[wc]<=0;bus.warp_fault[wc]<=SM_OK;
          if(bus.warp_cmd.detach)bus.warp_state[wc]<=SM_W_FREE;
          else begin
            bus.warp_state[wc]<=SM_W_RUN;bus.next_pc[wc]<=bus.warp_cmd.entry_pc;
            owner[wc]<=bus.warp_cmd.owner;generation[wc]<=bus.warp_cmd.generation;
            owner_history[bus.warp_cmd.owner]<=bus.warp_cmd.generation;
            active_mask[wc]<=bus.warp_cmd.active_mask;instance_counter[wc]<=1;
          end
        end
      end
      if(bus.fetch_valid && bus.fetch_ready)begin
        bus.fetch_rsp_valid<=1;bus.fetch_rsp.epoch<=bus.fetch.epoch;bus.fetch_rsp.owner<=bus.fetch.owner;
        bus.fetch_rsp.generation<=bus.fetch.generation;bus.fetch_rsp.warp<=bus.fetch.warp;
        bus.fetch_rsp.pc<=bus.fetch.pc;bus.fetch_rsp.status<=fetch_status;
        if(fetch_status==SM_OK)begin buffered[fw]<=bus.fetch;buffered_valid[fw]<=1;end
      end
      if(take)begin
        buffered_valid[int'(selected)]<=0;
        instance_counter[int'(selected)]<=instance_counter[int'(selected)]+1;
        if(selected_exec)begin
          queued_valid<=1;queued<=candidate;ticket_counter<=ticket_counter+1;
        end
        if(candidate.instr.op==SM_OP_EXIT)bus.warp_state[int'(selected)]<=SM_W_EXITED;
        else bus.next_pc[int'(selected)]<=candidate.instr.op==SM_OP_BRA ?
          candidate.instr.branch_target : candidate.pc+4;
      end
      for(int i=0;i<WARPS;i++)begin
        if(buffered_valid[i] && buffered[i].instr.op==SM_OP_EXEC &&
            buffered[i].instr.lane_mask!=0 && ticket_counter==32'hffffffff)begin
          buffered_valid[i]<=0;bus.warp_state[i]<=SM_W_FAULT;bus.warp_fault[i]<=SM_SEQUENCE_EXHAUSTED;
        end
        if(retire_valid && retire_status!=SM_OK && retire_token.warp==6'(i) &&
            owner[i]==retire_token.owner && generation[i]==retire_token.generation &&
            bus.warp_state[i]!=SM_W_FREE &&
            !(bus.warp_cmd_valid && bus.warp_cmd_ready && warp_command_status==SM_OK &&
              bus.warp_cmd.detach && wc==i))begin
          buffered_valid[i]<=0;bus.warp_state[i]<=SM_W_FAULT;bus.warp_fault[i]<=retire_status;
        end
      end
      if(protocol_error && bus.protocol_errors!=32'hffffffff)bus.protocol_errors<=bus.protocol_errors+1;
    end
  end
`ifdef SM_ASSERTIONS
  assert property(@(posedge bus.clk)disable iff(!bus.rst_n)
    reserve_valid&&reserve_ready |-> take&&selected_exec);
  assert property(@(posedge bus.clk)disable iff(!bus.rst_n)
    queued_valid |-> bus.warp_busy[int'(queued.token.warp)]);
`endif
endmodule

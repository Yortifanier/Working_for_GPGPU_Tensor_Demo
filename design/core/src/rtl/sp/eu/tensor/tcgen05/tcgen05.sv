// Tensor endpoint: independent control/resource credits and streaming MOVE,
// parallel-dot MMA, typed completion, and a full-duplex peer fabric.
module tcgen05 #(
  parameter int COLS = 576,
  parameter int LANES = 4,
  parameter int MAX_K = 256,
  parameter int MAX_M = 256,
  parameter int MAX_N = 256,
  parameter int DOT_ENGINES = 4,
  parameter int CHILDREN = 8,
  parameter int ISSUERS = 32,
  parameter int QUEUE_DEPTH = 4,
  parameter int COMMIT_DEPTH = 4,
  parameter int WAIT_DEPTH = 4,
  parameter bit ENABLE_FP64 = 1'b0
) (tcgen05_if.dut bus);
  import malu_pkg::*;
  import tcgen05_pkg::*;
  localparam int RECORDS = COLS/32;

  logic [TC_OWNERS-1:0] owner_live, owner_busy, owner_fault;
  logic [15:0] owner_generation [TC_OWNERS];
  tc_alloc_record_t records [RECORDS];
  logic alloc_cmd_valid, alloc_cmd_ready, alloc_rsp_valid, alloc_rsp_ready;
  tc_rsp_t alloc_rsp;
  logic engine_req_valid, engine_req_ready, engine_rsp_valid, engine_rsp_ready;
  tc_rsp_t engine_rsp;
  logic engine_aread_done;
  logic tm_req_valid, tm_req_ready, tm_rsp_valid, tm_rsp_ready;
  tc_mem_req_t tm_req;
  tc_mem_rsp_t tm_rsp;

  tc_cmd_t queue_cmd [QUEUE_DEPTH];
  integer queue_ctx [QUEUE_DEPTH];
  integer qread, qwrite, qcount;
  logic enqueue, dispatch;
  logic active;
  logic active_accounted;
  tc_cmd_t active_cmd;
  integer active_ctx;
  logic active_aread_seen;

  logic ctx_live [ISSUERS];
  logic [2:0] ctx_owner [ISSUERS];
  logic [15:0] ctx_generation [ISSUERS];
  logic [5:0] ctx_warp [ISSUERS];
  logic [4:0] ctx_lane [ISSUERS];
  logic ctx_fault [ISSUERS];
  logic [31:0] issued [ISSUERS], full_done [ISSUERS];
  logic [31:0] a_issued [ISSUERS], a_done [ISSUERS];
  logic [31:0] ld_issued [ISSUERS], ld_done [ISSUERS];
  logic [31:0] st_issued [ISSUERS], st_done [ISSUERS];
  logic ctx_referenced [ISSUERS];

  logic commit_live [COMMIT_DEPTH];
  tc_cmd_t commit_cmd [COMMIT_DEPTH];
  integer commit_ctx [COMMIT_DEPTH];
  logic [31:0] commit_cutoff [COMMIT_DEPTH];
  logic wait_live [WAIT_DEPTH];
  tc_cmd_t wait_cmd [WAIT_DEPTH];
  integer wait_ctx [WAIT_DEPTH];
  integer wait_warp_ctx [WAIT_DEPTH];
  logic wait_has_warp_ctx [WAIT_DEPTH];
  logic [31:0] wait_mcs [WAIT_DEPTH], wait_ld [WAIT_DEPTH], wait_st [WAIT_DEPTH];
  integer event_ctx;
  logic rsp_is_load;
  integer rsp_ctx;

  integer match_ctx, free_ctx, selected_ctx, warp_match_ctx;
  integer free_commit, ready_commit, free_wait, ready_wait;
  logic new_ctx, requires_ctx, needs_seq, have_wait, warp_stream_pending;
  logic rsp_space, immediate_space;
  logic drop_queued, finish_valid;
  tc_rsp_t finish_rsp;
  tc_status_e admission_status;
  logic accepted, immediate_response, accept_commit, accept_wait;

  initial begin
    if (COLS < 32 || COLS > 576 || COLS%32 != 0 || ISSUERS < 1 ||
        QUEUE_DEPTH < 1 || COMMIT_DEPTH < 1 || WAIT_DEPTH < 1 ||
        MAX_M < 1 || MAX_M > 256 || MAX_N < 1 || MAX_N > 256 ||
        MAX_K < 1 || MAX_K > 65535)
      $fatal(1,"Invalid tcgen05 parameters");
  end

  function automatic logic allocated(input tc_cmd_t c,
                                      input longint unsigned base,
                                      input longint unsigned count);
    logic found;
    found = 1'b0;
    if (count == 0 || base+count > 64'(COLS)) return 1'b0;
    for (int r=0; r<RECORDS; r++)
      if (records[r].live && !records[r].provisional && !records[r].release_pending && records[r].owner == c.owner &&
          records[r].owner_generation == c.owner_generation &&
          base >= 64'(records[r].base_col) &&
          base+count <= 64'(records[r].base_col)+64'(records[r].ncols))
        found = 1'b1;
    return found;
  endfunction
  function automatic logic smem_range(input tc_cmd_t c,
                                      input logic [31:0] address,
                                      input longint unsigned bytes);
    return address[1:0] == 0 && bytes != 0 &&
      64'(address)+bytes <= 64'(bus.owner_smem_bytes[c.owner]);
  endfunction
  function automatic longint unsigned element_words(input malu_fmt_e fmt);
    return (fmt == FMT_F64) ? 64'd2 : 64'd1;
  endfunction

  function automatic tc_status_e legacy_status(input tc_cmd_t c);
    longint unsigned a_words, b_words, c_words, d_words;
    longint unsigned a_cols, d_cols, block_len, a_scales, b_scales;
    malu_status_e mstatus;
    if (c.recipe != TC_RECIPE_WORD32_REF || c.cta_pair || c.sparse ||
        c.ws || c.ld_red || c.spcompress || c.collector || c.lut)
      return TC_UNSUPPORTED;
    if (!(c.op inside {TC_CTX_INIT,TC_CTX_RELEASE,TC_ALLOC,TC_DEALLOC,
        TC_RELINQUISH,TC_LD,TC_ST,TC_WAIT_LD,TC_WAIT_ST,TC_CP,TC_SHIFT,
        TC_MMA,TC_FENCE,TC_COMMIT})) return TC_BAD_CMD;
    if (is_collective(c.op)) begin
      if (c.participants != 32'hffffffff || c.thread_lane != 0) return TC_BAD_CMD;
    end else if (!(c.op inside {TC_CTX_INIT,TC_CTX_RELEASE}) &&
                 c.participants != (32'b1 << c.thread_lane)) return TC_BAD_CMD;
    if (c.op inside {TC_CTX_INIT,TC_CTX_RELEASE}) return TC_OK;
    if (!owner_live[c.owner] || owner_generation[c.owner] != c.owner_generation)
      return TC_BAD_OWNER;
    if (is_execution(c.op) && owner_fault[c.owner]) return TC_PRIOR_ERROR;
    case (c.op)
      TC_LD,TC_ST: begin
        if (c.ncols != 1) return TC_UNSUPPORTED;
        if (!allocated(c,64'(c.tmem_col),1)) return TC_BAD_ALLOC;
      end
      TC_CP: begin
        if (!allocated(c,64'(c.tmem_col),64'(c.ncols))) return TC_BAD_ALLOC;
        if (!smem_range(c,c.smem_addr,64'(c.ncols)*128*4)) return TC_RANGE;
      end
      TC_SHIFT: begin
        if (c.ncols != 8 || c.tmem_col[2:0] != 0) return TC_UNSUPPORTED;
        if (!allocated(c,64'(c.tmem_col),8)) return TC_BAD_ALLOC;
      end
      TC_MMA: begin
        if (c.m == 0 || int'(c.m) > MAX_M || c.n == 0 || int'(c.n) > MAX_N)
          return TC_RANGE;
        mstatus = cfg_status(c.cfg,MAX_K,ENABLE_FP64);
        if (mstatus != STATUS_OK) return TC_UNSUPPORTED;
        a_words = element_words(c.cfg.a_fmt);
        b_words = element_words(c.cfg.b_fmt);
        c_words = element_words(c.cfg.c_fmt);
        d_words = element_words(c.cfg.d_fmt);
        // Changing the in-place word stride could overwrite an unread old C.
        if (c.enable_input_d && c_words != d_words) return TC_UNSUPPORTED;
        a_cols = (64'(c.m)*64'(c.cfg.k)*a_words+127)/128;
        d_cols = (64'(c.m)*64'(c.n)*d_words+127)/128;
        if (!allocated(c,64'(c.d_col),d_cols)) return TC_BAD_ALLOC;
        if (c.a_from_tmem) begin
          if (!allocated(c,64'(c.a_col),a_cols)) return TC_BAD_ALLOC;
          if (64'(c.a_col) < 64'(c.d_col)+d_cols &&
              64'(c.d_col) < 64'(c.a_col)+a_cols) return TC_UNSUPPORTED;
        end else if (!smem_range(c,c.a_addr,64'(c.m)*64'(c.cfg.k)*a_words*4))
          return TC_RANGE;
        if (!smem_range(c,c.b_addr,64'(c.cfg.k)*64'(c.n)*b_words*4)) return TC_RANGE;
        if (c.cfg.block_scale_en) begin
          block_len = c.cfg.block_size == BLOCK16 ? 16 : 32;
          a_scales = (64'(c.cfg.k)+64'(c.cfg.a_block_offset)+block_len-1)/block_len;
          b_scales = (64'(c.cfg.k)+64'(c.cfg.b_block_offset)+block_len-1)/block_len;
          if (!smem_range(c,c.scale_a_addr,64'(c.m)*a_scales*4) ||
              !smem_range(c,c.scale_b_addr,64'(c.n)*b_scales*4)) return TC_RANGE;
        end
      end
      TC_COMMIT: if (c.barrier_addr[2:0] != 0 ||
                       !smem_range(c,c.barrier_addr,8)) return TC_RANGE;
      default: begin end
    endcase
    return TC_OK;
  endfunction


  typedef enum logic [2:0] {R_START,R_PIN_SEND,R_PIN_WAIT,R_RUN,R_UNPIN_SEND,R_UNPIN_WAIT,R_DONE} run_state_e;
  run_state_e run_state;
  tc_cmd_t normalized_cmd;
  tc_status_e form_status;
  malu_cfg_t unused_effective_cfg;
  logic [3:0] unused_scale_count_a,unused_scale_count_b;
  logic [TC_OWNERS-1:0] owner_pair;
  logic [3:0] hub_valid,hub_ready,hub_rvalid,hub_rready;
  tc_cmd_t hub_cmd[4]; tc_rsp_t hub_rsp[4];
  logic pa_req_ready,pc_req_ready,pa_rvalid,pc_rvalid,pa_rready,pc_rready;
  logic pa_busy,pc_busy; logic [2:0] pa_owner,pc_owner;
  tc_rsp_t pa_rsp,pc_rsp;
  logic [2:0] remote_valid,remote_ready,remote_rvalid,remote_rready;
  tc_cmd_t remote_cmd[3];tc_rsp_t remote_rsp[3];
  tc_rsp_t completed_rsp;
  logic [31:0] operation_sequence,active_token;
  logic account_done;
  logic [3:0] memory_valid,memory_ready,memory_rvalid,memory_rready;
  tc_mem_req_t memory_req[4]; tc_mem_rsp_t memory_rsp[4];
  logic memory_hold,return_busy; logic [2:0] memory_owner,return_owner;
  logic ram_valid,ram_ready,ram_rvalid,ram_rready;
  tc_mem_req_t ram_req; tc_mem_rsp_t ram_rsp;
  logic engine_svalid,engine_sready,engine_srvalid,engine_srready;
  tc_mem_req_t engine_sreq;tc_mem_rsp_t engine_srsp;
  logic ar_valid,ar_ready,ar_rvalid,ar_rready;
  tc_rsp_t ar_req,ar_rsp;
  integer ar_choice,ar_rr;
  logic child_live[CHILDREN];logic [2:0] child_owner[CHILDREN];
  logic [15:0] child_generation[CHILDREN];logic [31:0] child_id[CHILDREN];
  integer child_match,child_free;
  logic service_is_pin,service_allowed,service_immediate,service_space;
  tc_status_e service_status;
  logic fanout_valid,fanout_ready,fanout_busy;
  tc_event_t fanout_event;

  function automatic logic grouped(input tc_opcode_e op);
    return op inside {TC_ALLOC,TC_DEALLOC,TC_RELINQUISH,TC_CP,TC_SHIFT,TC_MMA,TC_COMMIT};
  endfunction
  function automatic tc_status_e resource_status(input tc_cmd_t c);
    if (c.op==TC_CTX_INIT) return owner_live[c.owner] ? TC_BUSY : TC_OK;
    if (!owner_live[c.owner] || owner_generation[c.owner]!=c.owner_generation) return TC_BAD_OWNER;
    if (grouped(c.op) && owner_pair[c.owner]!=c.cta_pair) return TC_BAD_CMD;
    if (is_execution(c.op) && owner_fault[c.owner]) return TC_PRIOR_ERROR;
    if (c.cta_pair && is_collective(c.op) && c.peer_participants!=32'hffffffff) return TC_BAD_CMD;
    if (!(is_collective(c.op) || c.op==TC_CTX_RELEASE) &&
        c.participants!=(32'b1<<c.thread_lane)) return TC_BAD_CMD;
    if (c.op==TC_CTX_RELEASE && ((pa_busy && pa_owner==c.owner) || (pc_busy && pc_owner==c.owner))) return TC_BUSY;
    if (c.cta_pair && c.op==TC_ALLOC && pa_busy) return TC_BUSY;
    if (c.cta_pair && c.op inside {TC_DEALLOC,TC_RELINQUISH} && pc_busy) return TC_BUSY;
    if (c.op==TC_RELINQUISH && pa_busy && pa_owner==c.owner) return TC_BUSY;
    if (c.op==TC_DEALLOC && owner_busy[c.owner]) return TC_BUSY;
    if (c.op==TC_ALLOC && c.recipe==TC_RECIPE_NATIVE &&
        !smem_range(c,c.smem_addr,4)) return TC_RANGE;
    if (c.op==TC_COMMIT && !c.barrier_remote && !c.multicast && !smem_range(c,c.barrier_addr,8)) return TC_RANGE;
    if (c.recipe==TC_RECIPE_WORD32_REF) return legacy_status(c);
    return TC_OK;
  endfunction
  tcgen05_legalize #(.MAX_K(MAX_K),.MAX_M(MAX_M),.MAX_N(MAX_N),.ENABLE_FP64(ENABLE_FP64)) legalizer (
    .cmd(bus.cmd),.caps(bus.capabilities),.strict_isa(bus.cmd.recipe==TC_RECIPE_NATIVE),
    .status(form_status),.normalized_cmd(normalized_cmd),.effective_cfg(unused_effective_cfg),
    .scale_count_a(unused_scale_count_a),.scale_count_b(unused_scale_count_b)
  );
  tcgen05_allocator_hub #(.COLS(COLS),.RECORDS(RECORDS)) allocation_hub (
    .clk(bus.clk),.rst_n(bus.rst_n),.cmd_valid(hub_valid),.cmd_ready(hub_ready),.cmd(hub_cmd),
    .rsp_valid(hub_rvalid),.rsp_ready(hub_rready),.rsp(hub_rsp),
    .owner_busy(owner_busy),.owner_fault(owner_fault),.owner_live(owner_live),
    .owner_generation(owner_generation),.records(records)
  );
  tcgen05_pair #(.COLS(COLS),.ALLOCATION_ONLY(1)) pair_allocate (
    .clk(bus.clk),.rst_n(bus.rst_n),.cancel(owner_fault[pa_owner]),
    .req_valid(accepted && admission_status==TC_OK && bus.cmd.cta_pair && bus.cmd.op==TC_ALLOC),
    .req_ready(pa_req_ready),.req(normalized_cmd),.rsp_valid(pa_rvalid),.rsp_ready(pa_rready),.rsp(pa_rsp),
    .local_valid(hub_valid[1]),.local_ready(hub_ready[1]),.local_cmd(hub_cmd[1]),
    .local_rsp_valid(hub_rvalid[1]),.local_rsp_ready(hub_rready[1]),.local_rsp(hub_rsp[1]),
    .remote_valid(remote_valid[0]),.remote_ready(remote_ready[0]),.remote_cmd(remote_cmd[0]),
    .remote_rsp_valid(remote_rvalid[0]),.remote_rsp_ready(remote_rready[0]),.remote_rsp(remote_rsp[0]),
    .busy(pa_busy),.busy_owner(pa_owner)
  );
  tcgen05_pair #(.COLS(COLS),.ALLOCATION_ONLY(0)) pair_control (
    .clk(bus.clk),.rst_n(bus.rst_n),.cancel(1'b0),
    .req_valid(accepted && admission_status==TC_OK && bus.cmd.cta_pair && bus.cmd.op inside {TC_DEALLOC,TC_RELINQUISH}),
    .req_ready(pc_req_ready),.req(normalized_cmd),.rsp_valid(pc_rvalid),.rsp_ready(pc_rready),.rsp(pc_rsp),
    .local_valid(hub_valid[2]),.local_ready(hub_ready[2]),.local_cmd(hub_cmd[2]),
    .local_rsp_valid(hub_rvalid[2]),.local_rsp_ready(hub_rready[2]),.local_rsp(hub_rsp[2]),
    .remote_valid(remote_valid[1]),.remote_ready(remote_ready[1]),.remote_cmd(remote_cmd[1]),
    .remote_rsp_valid(remote_rvalid[1]),.remote_rsp_ready(remote_rready[1]),.remote_rsp(remote_rsp[1]),
    .busy(pc_busy),.busy_owner(pc_owner)
  );
  tcgen05_control_mux control_link (
    .clk(bus.clk),.rst_n(bus.rst_n),.req_valid(remote_valid),.req_ready(remote_ready),.req(remote_cmd),
    .rsp_valid(remote_rvalid),.rsp_ready(remote_rready),.rsp(remote_rsp),
    .out_valid(bus.peer_cmd_valid),.out_ready(bus.peer_cmd_ready),.out_cmd(bus.peer_cmd),
    .out_rsp_valid(bus.peer_rsp_valid),.out_rsp_ready(bus.peer_rsp_ready),.out_rsp(bus.peer_rsp)
  );
  tcgen05_execute #(.COLS(COLS),.LANES(LANES),.MAX_K(MAX_K),.MAX_M(MAX_M),.MAX_N(MAX_N),
    .DOT_ENGINES(DOT_ENGINES),.ENABLE_FP64(ENABLE_FP64)) engine (
    .clk(bus.clk),.rst_n(bus.rst_n),.req_valid(engine_req_valid),.req_ready(engine_req_ready),.req(active_cmd),
    .rsp_valid(engine_rsp_valid),.rsp_ready(engine_rsp_ready),.rsp(engine_rsp),.aread_done(engine_aread_done),
    .rf_in_valid(bus.rf_in_valid),.rf_in_ready(bus.rf_in_ready),.rf_in(bus.rf_in),
    .rf_out_valid(bus.rf_out_valid),.rf_out_ready(bus.rf_out_ready),.rf_out(bus.rf_out),
    .tm_req_valid(tm_req_valid),.tm_req_ready(tm_req_ready),.tm_req(tm_req),
    .tm_rsp_valid(tm_rsp_valid),.tm_rsp_ready(tm_rsp_ready),.tm_rsp(tm_rsp),
    .smem_req_valid(engine_svalid),.smem_req_ready(engine_sready),.smem_req(engine_sreq),
    .smem_rsp_valid(engine_srvalid),.smem_rsp_ready(engine_srready),.smem_rsp(engine_srsp)
  );
  tcgen05_memory #(.COLS(COLS),.RECORDS(RECORDS)) memory (
    .clk(bus.clk),.rst_n(bus.rst_n),.reset_epoch(bus.reset_epoch),.owner_live(owner_live),.owner_fault(owner_fault),
    .owner_generation(owner_generation),.owner_smem_bytes(bus.owner_smem_bytes),.records(records),
    .req_valid(memory_valid),.req_ready(memory_ready),.req(memory_req),
    .rsp_valid(memory_rvalid),.rsp_ready(memory_rready),.rsp(memory_rsp),
    .local_valid(ram_valid),.local_ready(ram_ready),.local_req(ram_req),
    .local_rsp_valid(ram_rvalid),.local_rsp_ready(ram_rready),.local_rsp(ram_rsp),
    .smem_valid(bus.smem_req_valid),.smem_ready(bus.smem_req_ready),.smem_req(bus.smem_req),
    .smem_rsp_valid(bus.smem_rsp_valid),.smem_rsp_ready(bus.smem_rsp_ready),.smem_rsp(bus.smem_rsp),
    .peer_valid(bus.peer_mem_req_valid),.peer_ready(bus.peer_mem_req_ready),.peer_req(bus.peer_mem_req),
    .peer_rsp_valid(bus.peer_mem_rsp_valid),.peer_rsp_ready(bus.peer_mem_rsp_ready),.peer_rsp(bus.peer_mem_rsp),
    .hold_valid(memory_hold),.hold_owner(memory_owner)
  );
  tcgen05_tmem #(.COLS(COLS)) tmem (
    .clk(bus.clk),.rst_n(bus.rst_n),.req_valid(ram_valid),.req_ready(ram_ready),.req(ram_req),
    .rsp_valid(ram_rvalid),.rsp_ready(ram_rready),.rsp(ram_rsp)
  );
  tcgen05_alloc_return allocation_return (
    .clk(bus.clk),.rst_n(bus.rst_n),.req_valid(ar_valid),.req_ready(ar_ready),.req(ar_req),
    .rsp_valid(ar_rvalid),.rsp_ready(ar_rready),.rsp(ar_rsp),
    .mem_valid(memory_valid[3]),.mem_ready(memory_ready[3]),.mem_req(memory_req[3]),
    .mem_rsp_valid(memory_rvalid[3]),.mem_rsp_ready(memory_rready[3]),.mem_rsp(memory_rsp[3]),
    .busy(return_busy),.busy_owner(return_owner)
  );
  assign memory_valid[0]=tm_req_valid;assign memory_req[0]=tm_req;
  assign tm_req_ready=memory_ready[0];assign tm_rsp_valid=memory_rvalid[0];assign tm_rsp=memory_rsp[0];
  assign memory_rready[0]=tm_rsp_ready;
  assign memory_valid[1]=engine_svalid;assign memory_req[1]=engine_sreq;
  assign engine_sready=memory_ready[1];assign engine_srvalid=memory_rvalid[1];assign engine_srsp=memory_rsp[1];
  assign memory_rready[1]=engine_srready;
  assign memory_valid[2]=bus.service_mem_req_valid;assign memory_req[2]=bus.service_mem_req;
  assign bus.service_mem_req_ready=memory_ready[2];assign bus.service_mem_rsp_valid=memory_rvalid[2];
  assign bus.service_mem_rsp=memory_rsp[2];assign memory_rready[2]=bus.service_mem_rsp_ready;
  assign hub_cmd[0]=normalized_cmd;
  assign hub_valid[0]=bus.cmd_valid && admission_status==TC_OK && is_allocator(bus.cmd.op) &&
    (!bus.cmd.cta_pair || bus.cmd.op inside {TC_CTX_INIT,TC_CTX_RELEASE});
  assign hub_cmd[3]=bus.service_cmd;
  assign hub_valid[3]=bus.service_cmd_valid && !service_is_pin && service_allowed && service_status==TC_OK;
  always_comb begin
    ar_choice=-1;
    for (int off=0;off<3;off++) begin
      int s;s=ar_rr+off;if (s>=3) s=s-3;
      if (ar_choice<0 && (s==0 ? hub_rvalid[0] : s==1 ? pa_rvalid : pc_rvalid)) ar_choice=s;
    end
    ar_req=ar_choice==0 ? hub_rsp[0] : ar_choice==1 ? pa_rsp : pc_rsp;
  end
  // The return sink advertises idle without waiting for valid, so only a ready
  // transfer is offered; no arbitrated valid can change while backpressured.
  assign ar_valid=ar_choice>=0 && ar_ready;
  assign hub_rready[0]=ar_choice==0 && ar_ready;
  assign pa_rready=ar_choice==1 && ar_ready;
  assign pc_rready=ar_choice==2 && ar_ready;
  assign fanout_valid=ready_commit>=0 && fanout_ready;
  always_comb begin
    fanout_event='0;
    if (ready_commit>=0) begin
      fanout_event.tag=commit_cmd[ready_commit].tag;
      fanout_event.owner=commit_cmd[ready_commit].owner;
      fanout_event.owner_generation=commit_cmd[ready_commit].owner_generation;
      fanout_event.warp=commit_cmd[ready_commit].warp;
      fanout_event.thread_lane=commit_cmd[ready_commit].thread_lane;
      fanout_event.barrier_addr=commit_cmd[ready_commit].barrier_addr;
      fanout_event.restricted=commit_cmd[ready_commit].restricted;
      fanout_event.cutoff=commit_cutoff[ready_commit];
      fanout_event.multicast=commit_cmd[ready_commit].multicast;
      fanout_event.cta_mask=commit_cmd[ready_commit].cta_mask;
      fanout_event.mask_width32=commit_cmd[ready_commit].mask_width32;
      fanout_event.target_valid=commit_cmd[ready_commit].barrier_remote;
      fanout_event.target_cta=commit_cmd[ready_commit].barrier_target;
      fanout_event.arrive_count=1;
      fanout_event.status=ctx_fault[commit_ctx[ready_commit]] || owner_fault[commit_cmd[ready_commit].owner] ? TC_PRIOR_ERROR : TC_OK;
    end
  end
  tcgen05_commit_fanout commit_fanout (
    .clk(bus.clk),.rst_n(bus.rst_n),.req_valid(fanout_valid),.req_ready(fanout_ready),.req(fanout_event),
    .rsp_valid(bus.event_valid),.rsp_ready(bus.event_ready),.rsp(bus.event_data),.busy(fanout_busy)
  );
  always_comb begin
    for (int i=0; i<ISSUERS; i++) ctx_referenced[i] = 1'b0;
    for (int i=0; i<COMMIT_DEPTH; i++)
      if (commit_live[i]) ctx_referenced[commit_ctx[i]] = 1'b1;
    for (int i=0; i<WAIT_DEPTH; i++)
      if (wait_live[i]) begin
        ctx_referenced[wait_ctx[i]] = 1'b1;
        if (wait_has_warp_ctx[i]) ctx_referenced[wait_warp_ctx[i]] = 1'b1;
      end
    if (fanout_busy) ctx_referenced[event_ctx] = 1'b1;
    if (bus.rsp_valid && rsp_is_load) ctx_referenced[rsp_ctx] = 1'b1;
    if (active) ctx_referenced[active_ctx]=1'b1;
    match_ctx = -1;
    warp_match_ctx = -1;
    free_ctx = -1;
    for (int i=0; i<ISSUERS; i++) begin
      if (ctx_live[i] && ctx_owner[i] == bus.cmd.owner &&
          ctx_generation[i] == bus.cmd.owner_generation &&
          ctx_warp[i] == bus.cmd.warp && ctx_lane[i] == 0)
        warp_match_ctx = i;
      if (ctx_live[i] && ctx_owner[i] == bus.cmd.owner &&
          ctx_generation[i] == bus.cmd.owner_generation &&
          ctx_warp[i] == bus.cmd.warp && ctx_lane[i] == bus.cmd.thread_lane)
        match_ctx = i;
      if (free_ctx < 0 && (!ctx_live[i] ||
          (!ctx_fault[i] && issued[i] == full_done[i] && a_issued[i] == a_done[i] &&
           ld_issued[i] == ld_done[i] && st_issued[i] == st_done[i] && !ctx_referenced[i] &&
           !(bus.cmd.op == TC_FENCE && ctx_owner[i] == bus.cmd.owner &&
             ctx_generation[i] == bus.cmd.owner_generation &&
             ctx_warp[i] == bus.cmd.warp && ctx_lane[i] == 0 &&
             (ld_issued[i] != ld_done[i] || st_issued[i] != st_done[i])))))
        free_ctx = i;
    end
    new_ctx = match_ctx < 0;
    selected_ctx = new_ctx ? free_ctx : match_ctx;
    warp_stream_pending = warp_match_ctx >= 0 &&
      (ld_issued[warp_match_ctx] != ld_done[warp_match_ctx] ||
       st_issued[warp_match_ctx] != st_done[warp_match_ctx]);
    free_commit = -1;
    ready_commit = -1;
    for (int i=0; i<COMMIT_DEPTH; i++) begin
      if (!commit_live[i] && free_commit < 0) free_commit = i;
      if (commit_live[i] && ready_commit < 0 &&
          (commit_cmd[i].restricted ? a_done[commit_ctx[i]] : full_done[commit_ctx[i]])
            >= commit_cutoff[i]) ready_commit = i;
    end
    free_wait = -1;
    ready_wait = -1;
    have_wait = 1'b0;
    for (int i=0; i<WAIT_DEPTH; i++) begin
      if (!wait_live[i] && free_wait < 0) free_wait = i;
      if (wait_live[i]) begin
        have_wait = 1'b1;
        if (ready_wait < 0 && full_done[wait_ctx[i]] >= wait_mcs[i] &&
            (!wait_has_warp_ctx[i] || (ld_done[wait_warp_ctx[i]] >= wait_ld[i] &&
             st_done[wait_warp_ctx[i]] >= wait_st[i])))
          ready_wait = i;
      end
    end
    owner_busy = '0;
    for (int i=0; i<ISSUERS; i++)
      if (ctx_live[i] && (issued[i] != full_done[i] || a_issued[i] != a_done[i] ||
          ld_issued[i] != ld_done[i] || st_issued[i] != st_done[i] || ctx_referenced[i]))
        owner_busy[ctx_owner[i]] = 1'b1;
    for (int i=0;i<CHILDREN;i++) if (child_live[i]) owner_busy[child_owner[i]]=1'b1;
    if (memory_hold) owner_busy[memory_owner]=1'b1;
    if (return_busy) owner_busy[return_owner]=1'b1;
  end

  always_comb begin
    admission_status=form_status==TC_OK ? resource_status(normalized_cmd) : form_status;
    requires_ctx=is_execution(bus.cmd.op) || bus.cmd.op inside {TC_COMMIT,TC_WAIT_LD,TC_WAIT_ST,TC_FENCE};
    needs_seq=is_execution(bus.cmd.op);
    if (admission_status==TC_OK && requires_ctx && selected_ctx<0) admission_status=TC_BUSY;
    if (admission_status==TC_OK && needs_seq && !new_ctx) begin
      if ((is_mcs(bus.cmd.op) && issued[selected_ctx]==32'hffffffff) ||
          (bus.cmd.op==TC_MMA && !bus.cmd.a_from_tmem && a_issued[selected_ctx]==32'hffffffff) ||
          (bus.cmd.op==TC_LD && ld_issued[selected_ctx]==32'hffffffff) ||
          (bus.cmd.op==TC_ST && st_issued[selected_ctx]==32'hffffffff)) admission_status=TC_SEQUENCE_EXHAUSTED;
    end
  end
  assign rsp_space=!bus.rsp_valid || bus.rsp_ready;
  assign finish_valid=active && run_state==R_DONE;
  assign finish_rsp=completed_rsp;
  assign account_done=finish_valid && !active_accounted;
  assign engine_req_valid=active && run_state==R_START;
  assign engine_rsp_ready=active && run_state==R_RUN;
  assign dispatch=qcount!=0 && !active;
  assign drop_queued=dispatch && owner_fault[queue_cmd[qread].owner];
  assign immediate_space=rsp_space && !finish_valid && ready_wait<0 && !ar_rvalid;
  assign ar_rready=rsp_space && !finish_valid && ready_wait<0;
  always_comb begin
    bus.cmd_ready=1'b0;
    if (admission_status!=TC_OK) bus.cmd_ready=immediate_space;
    else if (is_allocator(bus.cmd.op)) begin
      if (bus.cmd.cta_pair && bus.cmd.op==TC_ALLOC) bus.cmd_ready=pa_req_ready;
      else if (bus.cmd.cta_pair && bus.cmd.op inside {TC_DEALLOC,TC_RELINQUISH}) bus.cmd_ready=pc_req_ready;
      else bus.cmd_ready=hub_ready[0];
    end else if (is_execution(bus.cmd.op)) bus.cmd_ready=qcount<QUEUE_DEPTH && !have_wait;
    else if (bus.cmd.op==TC_COMMIT) bus.cmd_ready=free_commit>=0 && immediate_space;
    else bus.cmd_ready=free_wait>=0;
    accepted=bus.cmd_valid && bus.cmd_ready;
    enqueue=accepted && admission_status==TC_OK && is_execution(bus.cmd.op);
    accept_commit=accepted && admission_status==TC_OK && bus.cmd.op==TC_COMMIT;
    accept_wait=accepted && admission_status==TC_OK && bus.cmd.op inside {TC_WAIT_LD,TC_WAIT_ST,TC_FENCE};
    immediate_response=accepted && (admission_status!=TC_OK || bus.cmd.op==TC_COMMIT);
    remote_cmd[2]=active_cmd;
    remote_cmd[2].op=run_state==R_UNPIN_SEND || run_state==R_UNPIN_WAIT ? TC_PAIR_UNPIN : TC_PAIR_PIN;
    remote_cmd[2].owner=active_cmd.peer_owner;
    remote_cmd[2].owner_generation=active_cmd.peer_generation;
    remote_cmd[2].cta_pair=0;
    remote_cmd[2].reservation_id=active_token;
  end
  assign remote_valid[2]=active && run_state inside {R_PIN_SEND,R_UNPIN_SEND};
  assign remote_rready[2]=active && run_state inside {R_PIN_WAIT,R_UNPIN_WAIT};

  always_comb begin
    child_match=-1;child_free=-1;
    for (int i=0;i<CHILDREN;i++) begin
      if (!child_live[i] && child_free<0) child_free=i;
      if (child_live[i] && child_owner[i]==bus.service_cmd.owner &&
          child_generation[i]==bus.service_cmd.owner_generation &&
          child_id[i]==bus.service_cmd.reservation_id) child_match=i;
    end
    service_is_pin=bus.service_cmd.op inside {TC_PAIR_PIN,TC_PAIR_UNPIN};
    service_allowed=bus.service_cmd.op inside {TC_PAIR_PREPARE,TC_PAIR_PUBLISH,TC_PAIR_ROLLBACK,
      TC_PAIR_FREE_PREPARE,TC_PAIR_FREE_COMMIT,TC_PAIR_FREE_CANCEL,TC_RELINQUISH};
    service_status=TC_OK;
    if (!owner_live[bus.service_cmd.owner] ||
        owner_generation[bus.service_cmd.owner]!=bus.service_cmd.owner_generation) service_status=TC_BAD_OWNER;
    else if (!owner_pair[bus.service_cmd.owner]) service_status=TC_BAD_CMD;
    else if (bus.service_cmd.reservation_id==0 && service_is_pin) service_status=TC_BAD_CMD;
    else if (bus.service_cmd.op==TC_PAIR_PIN && owner_fault[bus.service_cmd.owner]) service_status=TC_PRIOR_ERROR;
    else if (bus.service_cmd.op==TC_PAIR_PIN && child_match<0 && child_free<0) service_status=TC_BUSY;
    else if (bus.service_cmd.op==TC_PAIR_UNPIN && child_match<0) service_status=TC_BAD_ALLOC;
    else if (!service_is_pin && !service_allowed) service_status=TC_BAD_CMD;
  end
  assign service_space=!bus.service_rsp_valid || bus.service_rsp_ready;
  assign bus.service_cmd_ready=service_is_pin || !service_allowed || service_status!=TC_OK ?
    (service_space && !hub_rvalid[3]) : hub_ready[3];
  assign hub_rready[3]=service_space;
  assign service_immediate=bus.service_cmd_valid && bus.service_cmd_ready &&
    (service_is_pin || !service_allowed || service_status!=TC_OK);
  always_ff @(posedge bus.clk or negedge bus.rst_n) begin
    if (!bus.rst_n) begin
      bus.service_rsp_valid<=0;bus.service_rsp<='0;
      for (int i=0;i<CHILDREN;i++) begin child_live[i]<=0;child_owner[i]<=0;child_generation[i]<=0;child_id[i]<=0;end
    end else begin
      if (hub_rvalid[3] && hub_rready[3]) begin bus.service_rsp_valid<=1;bus.service_rsp<=hub_rsp[3];end
      else if (service_immediate) begin
        bus.service_rsp_valid<=1;bus.service_rsp<=response_for(bus.service_cmd,service_status);
      end else if (bus.service_rsp_ready) bus.service_rsp_valid<=0;
      if (service_immediate && service_status==TC_OK) begin
        if (bus.service_cmd.op==TC_PAIR_PIN && child_match<0) begin
          child_live[child_free]<=1;child_owner[child_free]<=bus.service_cmd.owner;
          child_generation[child_free]<=bus.service_cmd.owner_generation;
          child_id[child_free]<=bus.service_cmd.reservation_id;
        end else if (bus.service_cmd.op==TC_PAIR_UNPIN) child_live[child_match]<=0;
      end
    end
  end

  always_ff @(posedge bus.clk or negedge bus.rst_n) begin
    if (!bus.rst_n) begin
      active<=0;active_cmd<='0;active_ctx<=0;active_aread_seen<=0;active_accounted<=0;
      completed_rsp<='0;run_state<=R_START;operation_sequence<=1;active_token<=0;
    end else begin
      if (dispatch) begin
        active<=1;active_cmd<=queue_cmd[qread];active_ctx<=queue_ctx[qread];
        active_aread_seen<=0;active_accounted<=0;active_token<=operation_sequence;
        if (operation_sequence!=32'hffffffff) operation_sequence<=operation_sequence+1;
        if (drop_queued || operation_sequence==32'hffffffff) begin
          completed_rsp<=response_for(queue_cmd[qread],drop_queued ? TC_PRIOR_ERROR : TC_SEQUENCE_EXHAUSTED);
          run_state<=R_DONE;
        end else run_state<=queue_cmd[qread].cta_pair ? R_PIN_SEND : R_START;
      end
      if (active && engine_aread_done) active_aread_seen<=1;
      if (account_done) active_accounted<=1;
      if (active) case (run_state)
        R_START: if (engine_req_ready) run_state<=R_RUN;
        R_PIN_SEND: if (remote_ready[2]) run_state<=R_PIN_WAIT;
        R_PIN_WAIT: if (remote_rvalid[2]) begin
          if (remote_rsp[2].status==TC_OK) run_state<=R_START;
          else if (remote_rsp[2].status==TC_BUSY) run_state<=R_PIN_SEND;
          else begin completed_rsp<=response_for(active_cmd,remote_rsp[2].status);run_state<=R_DONE;end
        end
        R_RUN: if (engine_rsp_valid) begin
          completed_rsp<=engine_rsp;
          run_state<=active_cmd.cta_pair ? R_UNPIN_SEND : R_DONE;
        end
        R_UNPIN_SEND: if (remote_ready[2]) run_state<=R_UNPIN_WAIT;
        R_UNPIN_WAIT: if (remote_rvalid[2]) begin
          if (remote_rsp[2].status!=TC_OK) completed_rsp.status<=TC_MEM_ERROR;
          run_state<=R_DONE;
        end
        R_DONE: if (rsp_space) active<=0;
        default: run_state<=R_DONE;
      endcase
    end
  end
  always_ff @(posedge bus.clk or negedge bus.rst_n) begin
    if (!bus.rst_n) begin
      bus.rsp_valid <= 1'b0;
      bus.rsp <= '0;
      owner_fault <= '0;
      qread <= 0; qwrite <= 0; qcount <= 0;
      owner_pair<='0;ar_rr<=0;
      event_ctx <= 0; rsp_is_load <= 1'b0; rsp_ctx <= 0;
      for (int i=0; i<ISSUERS; i++) begin
        ctx_live[i] <= 1'b0; ctx_owner[i] <= '0; ctx_generation[i] <= '0;
        ctx_warp[i] <= '0; ctx_lane[i] <= '0; ctx_fault[i] <= 1'b0;
        issued[i] <= 0; full_done[i] <= 0; a_issued[i] <= 0; a_done[i] <= 0;
        ld_issued[i] <= 0; ld_done[i] <= 0; st_issued[i] <= 0; st_done[i] <= 0;
      end
      for (int i=0; i<COMMIT_DEPTH; i++) begin
        commit_live[i] <= 1'b0; commit_cmd[i] <= '0; commit_ctx[i] <= 0;
        commit_cutoff[i] <= 0;
      end
      for (int i=0; i<WAIT_DEPTH; i++) begin
        wait_live[i] <= 1'b0; wait_cmd[i] <= '0; wait_ctx[i] <= 0;
        wait_warp_ctx[i] <= 0; wait_has_warp_ctx[i] <= 1'b0;
        wait_mcs[i] <= 0; wait_ld[i] <= 0; wait_st[i] <= 0;
      end
    end else begin
      if (bus.rsp_valid && bus.rsp_ready) begin
        bus.rsp_valid <= 1'b0;
        if (rsp_is_load) ld_done[rsp_ctx] <= ld_done[rsp_ctx]+1;
        rsp_is_load <= 1'b0;
      end

      if (accepted && admission_status == TC_OK && requires_ctx && new_ctx) begin
        ctx_live[selected_ctx] <= 1'b1;
        ctx_owner[selected_ctx] <= bus.cmd.owner;
        ctx_generation[selected_ctx] <= bus.cmd.owner_generation;
        ctx_warp[selected_ctx] <= bus.cmd.warp;
        ctx_lane[selected_ctx] <= bus.cmd.thread_lane;
        ctx_fault[selected_ctx] <= 1'b0;
        issued[selected_ctx] <= (enqueue && is_mcs(bus.cmd.op)) ? 1 : 0;
        full_done[selected_ctx] <= 0;
        a_issued[selected_ctx] <= (enqueue && bus.cmd.op == TC_MMA && !bus.cmd.a_from_tmem) ? 1 : 0;
        a_done[selected_ctx] <= 0;
        ld_issued[selected_ctx] <= (enqueue && bus.cmd.op == TC_LD) ? 1 : 0;
        ld_done[selected_ctx] <= 0;
        st_issued[selected_ctx] <= (enqueue && bus.cmd.op == TC_ST) ? 1 : 0;
        st_done[selected_ctx] <= 0;
      end
      if (enqueue) begin
        queue_cmd[qwrite] <= normalized_cmd;
        queue_ctx[qwrite] <= selected_ctx;
        qwrite <= qwrite == QUEUE_DEPTH-1 ? 0 : qwrite+1;
        if (!new_ctx) begin
          if (is_mcs(bus.cmd.op)) issued[selected_ctx] <= issued[selected_ctx]+1;
          if (bus.cmd.op == TC_MMA && !bus.cmd.a_from_tmem)
            a_issued[selected_ctx] <= a_issued[selected_ctx]+1;
          if (bus.cmd.op == TC_LD) ld_issued[selected_ctx] <= ld_issued[selected_ctx]+1;
          if (bus.cmd.op == TC_ST) st_issued[selected_ctx] <= st_issued[selected_ctx]+1;
        end
      end
      if (dispatch) qread <= qread == QUEUE_DEPTH-1 ? 0 : qread+1;
      if (ar_valid && ar_ready) ar_rr <= ar_choice==2 ? 0 : ar_choice+1;
      if (accepted && admission_status==TC_OK && bus.cmd.op==TC_CTX_INIT) begin
        owner_pair[bus.cmd.owner]<=bus.cmd.cta_pair;
        owner_fault[bus.cmd.owner]<=0;
      end
      case ({enqueue,dispatch})
        2'b10: qcount <= qcount+1;
        2'b01: qcount <= qcount-1;
        default: begin end
      endcase
      if (active && engine_aread_done) begin
        a_done[active_ctx] <= a_done[active_ctx]+1;

      end
      if (account_done) begin
        if (is_mcs(active_cmd.op)) full_done[active_ctx]<=full_done[active_ctx]+1;
        if (active_cmd.op==TC_ST) st_done[active_ctx]<=st_done[active_ctx]+1;
        if (active_cmd.op==TC_LD && active_cmd.rf_stream) ld_done[active_ctx]<=ld_done[active_ctx]+1;
        if (active_cmd.op==TC_MMA && !active_cmd.a_from_tmem && !active_aread_seen && !engine_aread_done)
          a_done[active_ctx]<=a_done[active_ctx]+1;
        if (finish_rsp.status!=TC_OK) begin ctx_fault[active_ctx]<=1;owner_fault[active_cmd.owner]<=1;end
      end
      if (finish_valid && rsp_space) begin
        bus.rsp_valid<=1;bus.rsp<=finish_rsp;
        rsp_is_load<=active_cmd.op==TC_LD && !active_cmd.rf_stream;rsp_ctx<=active_ctx;
      end else if (rsp_space && ready_wait >= 0) begin
        bus.rsp_valid <= 1'b1;
        bus.rsp <= response_for(wait_cmd[ready_wait],
          (ctx_fault[wait_ctx[ready_wait]] || owner_fault[wait_cmd[ready_wait].owner]) ? TC_PRIOR_ERROR : TC_OK);
        rsp_is_load <= 1'b0;
        wait_live[ready_wait] <= 1'b0;
      end else if (ar_rvalid && ar_rready) begin
        bus.rsp_valid <= 1'b1;
        bus.rsp <= ar_rsp;
        rsp_is_load <= 1'b0;
        if (ar_rsp.status==TC_MEM_ERROR &&
            owner_generation[ar_rsp.owner]==ar_rsp.owner_generation)
          owner_fault[ar_rsp.owner]<=1;
        if (ar_rsp.status == TC_OK && ar_rsp.op == TC_CTX_RELEASE) begin
          if (owner_generation[ar_rsp.owner]==ar_rsp.owner_generation &&
              !(accepted && admission_status==TC_OK && bus.cmd.op==TC_CTX_INIT &&
                bus.cmd.owner==ar_rsp.owner)) owner_fault[ar_rsp.owner] <= 1'b0;
          // A newer INIT may already have passed the allocator while this
          // response waited at the core port. Its group and issuer state are
          // unrelated to the released generation; INIT always sets the group.
          for (int i=0; i<ISSUERS; i++)
            if (ctx_owner[i] == ar_rsp.owner &&
                ctx_generation[i] == ar_rsp.owner_generation &&
                !(accepted && admission_status == TC_OK && requires_ctx &&
                  new_ctx && selected_ctx == i)) ctx_live[i] <= 1'b0;
        end
      end else if (immediate_response) begin
        bus.rsp_valid <= 1'b1;
        bus.rsp <= response_for(bus.cmd,admission_status);
        rsp_is_load <= 1'b0;
      end

      if (accept_commit) begin
        commit_live[free_commit] <= 1'b1;
        commit_cmd[free_commit] <= normalized_cmd;
        commit_ctx[free_commit] <= selected_ctx;
        commit_cutoff[free_commit] <= new_ctx ? 0 :
          (bus.cmd.restricted ? a_issued[selected_ctx] : issued[selected_ctx]);
      end
      if (accept_wait) begin
        wait_live[free_wait] <= 1'b1;
        wait_cmd[free_wait] <= normalized_cmd;
        wait_ctx[free_wait] <= selected_ctx;
        wait_has_warp_ctx[free_wait] <= warp_stream_pending;
        wait_warp_ctx[free_wait] <= warp_match_ctx >= 0 ? warp_match_ctx : 0;
        wait_mcs[free_wait] <= (!new_ctx && bus.cmd.op == TC_FENCE) ? issued[selected_ctx] : 0;
        wait_ld[free_wait] <= (warp_stream_pending && bus.cmd.op inside {TC_WAIT_LD,TC_FENCE}) ? ld_issued[warp_match_ctx] : 0;
        wait_st[free_wait] <= (warp_stream_pending && bus.cmd.op inside {TC_WAIT_ST,TC_FENCE}) ? st_issued[warp_match_ctx] : 0;
      end
      if (fanout_valid && fanout_ready) begin
        event_ctx <= commit_ctx[ready_commit];
        commit_live[ready_commit] <= 1'b0;
      end
    end
  end
`ifdef TCGEN05_ASSERTIONS
  for (genvar i=0; i<ISSUERS; i++) begin : g_stream_assert
    assert property (@(posedge bus.clk) disable iff (!bus.rst_n)
      full_done[i] <= issued[i] && a_done[i] <= a_issued[i] &&
      ld_done[i] <= ld_issued[i] && st_done[i] <= st_issued[i])
      else $error("context %0d full=%0d/%0d A=%0d/%0d LD=%0d/%0d ST=%0d/%0d",
        i,full_done[i],issued[i],a_done[i],a_issued[i],ld_done[i],ld_issued[i],st_done[i],st_issued[i]);
  end
  assert property (@(posedge bus.clk) disable iff (!bus.rst_n)
    qcount >= 0 && qcount <= QUEUE_DEPTH);
  assert property (@(posedge bus.clk) disable iff (!bus.rst_n)
    engine_aread_done |-> active && active_cmd.op == TC_MMA &&
      !active_cmd.a_from_tmem && !active_aread_seen);
`endif
endmodule

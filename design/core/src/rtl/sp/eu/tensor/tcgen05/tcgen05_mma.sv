// Tensor MMA semantic engine. Several output dots own independent MALU cores;
// the operand/metadata/scale reader is shared and visits ready contexts fairly.
// PTX physical addresses are supplied by tcgen05_layout_pkg, independently of
// the canonical packed test layout. No physical NVIDIA array count is inferred.
module tcgen05_mma #(
  parameter int COLS = 576,
  parameter int LANES = 4,
  parameter int MAX_K = 256,
  parameter int MAX_M = 256,
  parameter int MAX_N = 256,
  parameter int DOT_ENGINES = 4,
  parameter bit ENABLE_FP64 = 1'b1
) (
  input logic clk,rst_n,
  input logic req_valid,
  output logic req_ready,
  input tcgen05_pkg::tc_cmd_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output tcgen05_pkg::tc_rsp_t rsp,
  output logic aread_done,
  output logic tm_req_valid,
  input logic tm_req_ready,
  output tcgen05_pkg::tc_mem_req_t tm_req,
  input logic tm_rsp_valid,
  output logic tm_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t tm_rsp,
  output logic smem_req_valid,
  input logic smem_req_ready,
  output tcgen05_pkg::tc_mem_req_t smem_req,
  input logic smem_rsp_valid,
  output logic smem_rsp_ready,
  input tcgen05_pkg::tc_mem_rsp_t smem_rsp
);
  import malu_pkg::*;
  import tcgen05_pkg::*;
  import tcgen05_layout_pkg::*;
  localparam int COUNT_W=$clog2(LANES+1);
  typedef enum logic [5:0] {
    M_IDLE,M_VALIDATE,M_RUN,M_BEGIN_DOT,M_C_CAPTURE,M_SEND_DESC,
    M_PREP_BEAT,M_SCALE_A,M_SCALE_A_CAPTURE,M_SCALE_B,M_SCALE_B_CAPTURE,
    M_GET_A,M_META_CAPTURE,M_A_CAPTURE,M_GET_B,M_B_CAPTURE,M_LUT_CAPTURE,
    M_ELEMENT_NEXT,M_SEND_BEAT,M_D_WRITE,M_D_HIGH,M_D_FINISH,
    M_ASHIFT_BEGIN,M_ASHIFT_READ,M_ASHIFT_WRITE,M_ASHIFT_NEXT,
    M_READ_CAPTURE,M_MEM_SEND,M_MEM_WAIT,M_FINISH,M_RESPOND,M_WRITEBACK_FETCH
  } state_e;
  state_e state,mem_return,read_return;
  tc_cmd_t cmd;
  tc_rsp_t response;
  logic [DOT_ENGINES-1:0] context_live;
  int unsigned context_m[DOT_ENGINES],context_n[DOT_ENGINES];
  int unsigned context_k[DOT_ENGINES];
  int unsigned context_result_index[DOT_ENGINES];
  logic [63:0] context_c[DOT_ENGINES];
  logic context_meta_valid[DOT_ENGINES];
  int unsigned context_meta_group[DOT_ENGINES];
  logic [3:0] context_meta[DOT_ENGINES];
  int current_context,probe_context,free_context,response_context;
  int unsigned next_m,next_n;
  logic all_created;
  int unsigned completed_dots,total_dots,logical_a_captured,a_dots_captured;
  // One shared tile RAM delays all D writes until every source/old-C value has
  // been consumed. This also protects A, metadata, scales and LUT when their
  // physical allocations alias D. Entries are written before read, not reset.
  localparam int TILE_WORDS=MAX_M*MAX_N;
  logic [31:0] result_low[0:TILE_WORDS-1];
  logic [31:0] result_high[0:TILE_WORDS-1];
  logic writing_back;
  int unsigned writeback_index,writeback_m,writeback_n;

  logic array_run,array_req_valid,array_req_ready;
  logic array_op_valid,array_op_ready,array_rsp_valid,array_rsp_ready;
  logic [15:0] array_req_tag,array_op_tag,array_rsp_tag;
  logic [63:0] array_rsp_data;
  malu_status_e array_rsp_status;
  logic [DOT_ENGINES-1:0] array_busy;
  int unsigned beat_count,lane_slot,next_count,logical_k;
  logic [LANES-1:0][63:0] beat_a,beat_b;
  logic [7:0] scale_a,scale_b;
  logic [63:0] d_value;
  tc_access_t d_location;
  logic d_disabled;

  tc_mem_req_t memory_request;
  tc_access_t read_origin;
  logic memory_is_smem,read_is_smem;
  logic [63:0] memory_sequence;
  logic [31:0] memory_data;
  logic [95:0] read_buffer,read_merged;
  logic [63:0] read_value;
  int unsigned read_width,read_index,read_words;
  int unsigned a_span,b_span,a_scale_index,b_scale_index;
  int unsigned a_room,b_room,sparse_granularity,sparse_group,stored_k;
  logic a_present,metadata_valid;
  int unsigned zero_column_shift;
  logic zero_b;
  int unsigned shift_row,shift_word,shift_words,shift_copy,shift_copies,shift_output_n;
  logic [31:0] shift_data;

  // A collector hit is optional in PTX. This implementation tracks legal
  // fill/use/lastuse lifetime but deliberately rereads the protected memory
  // object, rather than caching stale SMEM/TMEM data across commands.
  logic collector_a_valid[TC_OWNERS];
  logic collector_b_valid[TC_OWNERS][4];
  logic [15:0] collector_a_generation[TC_OWNERS];
  logic [15:0] collector_b_generation[TC_OWNERS][4];

  initial begin
    if (COLS<32 || COLS>576 || LANES<1 || LANES>32 || DOT_ENGINES<1 ||
        DOT_ENGINES>128 || MAX_K<1 || MAX_K>65535 || MAX_M<1 || MAX_M>256 ||
        MAX_N<1 || MAX_N>256) $fatal(1,"Invalid tcgen05_mma parameters");
  end
  assign req_ready=state==M_IDLE;
  assign rsp_valid=state==M_RESPOND;
  assign rsp=response;
  assign tm_req=memory_request;
  assign smem_req=memory_request;
  assign tm_req_valid=state==M_MEM_SEND && !memory_is_smem;
  assign smem_req_valid=state==M_MEM_SEND && memory_is_smem;
  assign tm_rsp_ready=state==M_MEM_WAIT && !memory_is_smem;
  assign smem_rsp_ready=state==M_MEM_WAIT && memory_is_smem;
  assign array_req_valid=state==M_SEND_DESC;
  assign array_req_tag=16'(current_context);
  assign array_op_valid=state==M_SEND_BEAT;
  assign array_op_tag=16'(state==M_RUN ? probe_context : current_context);
  assign array_rsp_ready=state==M_RUN;

  tcgen05_dot_array #(.ENGINES(DOT_ENGINES),.LANES(LANES),.TAG_W(16),
    .MAX_K(MAX_K),.ENABLE_FP64(ENABLE_FP64)) arithmetic (
    .clk(clk),.rst_n(rst_n && array_run),
    .req_valid(array_req_valid),.req_ready(array_req_ready),.req_cfg(cmd.cfg),
    .req_c(context_c[current_context]),.req_tag(array_req_tag),
    .op_valid(array_op_valid),.op_ready(array_op_ready),.op_tag(array_op_tag),
    .op_a(beat_a),.op_b(beat_b),.op_count(COUNT_W'(beat_count)),
    .op_scale_a(scale_a),.op_scale_b(scale_b),
    .op_last(context_k[current_context]+beat_count==32'(cmd.cfg.k)),
    .rsp_valid(array_rsp_valid),.rsp_ready(array_rsp_ready),
    .rsp_tag(array_rsp_tag),.rsp_data(array_rsp_data),.rsp_status(array_rsp_status),
    .busy_mask(array_busy)
  );

  function automatic logic [63:0] width_mask(input int unsigned bits);
    return bits>=64 ? 64'hffffffffffffffff : (64'd1<<bits)-1;
  endfunction
  function automatic logic [63:0] negate_value(input logic [63:0] value,
                                               input malu_fmt_e fmt,
                                               input logic enabled);
    logic [63:0] result;
    result=value & width_mask(fmt_width(fmt));
    if (enabled) begin
      if (is_fp(fmt)) result=result^(64'd1<<(fmt_width(fmt)-1));
      else result=(~result+1)&width_mask(fmt_width(fmt));
    end
    return result;
  endfunction
  function automatic int unsigned scale_span(input int unsigned k,
                                              input int unsigned count,
                                              input int unsigned fallback);
    case (count)
      1: return k;
      2: return k>>1;
      3: return k==192 ? 64 : (k==96 ? 32 : k/3);
      4: return k>>2;
      6: return k==192 ? 32 : (k==96 ? 16 : k/6);
      8: return k>>3;
      default: return fallback;
    endcase
  endfunction
  function automatic logic zero_column(input tc_cmd_t c,input int unsigned n);
    int unsigned parts,length,part,local_col,start,zero_length,one_length,position;
    logic first;
    if (!c.ws || !c.zero_column_mask_desc[39]) return 1'b0;
    parts=128/32'(c.m);
    if (parts==0 || parts>4) return 1'b0;
    length=32'(c.n)/parts;
    if (length==0) return 1'b0;
    part=n/length;
    local_col=n%length;
    start=32'(c.zero_column_mask_desc[8*part+:8]);
    first=c.zero_column_mask_desc[32+part];
    // PTX9.4 PDF729 examples: skip=2,use=3,fs=0 => ...1110000.
    // This implements those explicit examples; Table56's prose labels for
    // skip/use span are interchanged relative to the illustrated bit strings.
    zero_length=32'(c.zero_column_mask_desc[55:48])+1;
    one_length=32'(c.zero_column_mask_desc[47:40])+1;
    position=(local_col+start)%(zero_length+one_length);
    if (first) return position<one_length;
    return position>=zero_length;
  endfunction

  always_comb begin
    free_context=-1;
    for (int i=0;i<DOT_ENGINES;i++)
      if (!context_live[i] && free_context<0) free_context=i;
    response_context=int'(array_rsp_tag);
    read_merged=read_buffer;
    read_merged[32*read_index+:32]=memory_data;
    logical_k=context_k[current_context]+lane_slot;
    sparse_granularity=4;
    if (cmd.kind==TC_KIND_TF32) sparse_granularity=2;
    else if (cmd.kind inside {TC_KIND_MXF4,TC_KIND_MXF4NVF4}) sparse_granularity=8;
    sparse_group=logical_k/sparse_granularity;
    metadata_valid=1'b1;
    a_present=1'b1;
    stored_k=logical_k;
    if (cmd.sparse) begin
      if (cmd.kind==TC_KIND_TF32) begin
        metadata_valid=context_meta[current_context] inside {4'he,4'h4};
        a_present=(logical_k%2)==(context_meta[current_context]==4'he ? 1 : 0);
        stored_k=logical_k>>1;
      end else begin
        metadata_valid=context_meta[current_context] inside
          {4'h4,4'h8,4'hc,4'h9,4'hd,4'h6,4'he};
        if (sparse_granularity==8) begin
          a_present=((logical_k%8)>>1)==32'(context_meta[current_context][1:0]) ||
                    ((logical_k%8)>>1)==32'(context_meta[current_context][3:2]);
          stored_k=sparse_group*4+(((logical_k%8)>>1)==32'(context_meta[current_context][1:0]) ? 0 : 2)+(logical_k%2);
        end else begin
          a_present=(logical_k%4)==32'(context_meta[current_context][1:0]) ||
                    (logical_k%4)==32'(context_meta[current_context][3:2]);
          stored_k=sparse_group*2+((logical_k%4)==32'(context_meta[current_context][1:0]) ? 0 : 1);
        end
      end
    end
    // Canonical/project counts describe storage length, including an initial
    // offset. Only native scale-vector aliases change the logical chunk span.
    a_span=cmd.recipe==TC_RECIPE_NATIVE ?
      scale_span(32'(cmd.cfg.k),32'(cmd.scale_count_a),cmd.cfg.block_size==BLOCK16 ? 16 : 32) :
      (cmd.cfg.block_size==BLOCK16 ? 16 : 32);
    b_span=cmd.recipe==TC_RECIPE_NATIVE ?
      scale_span(32'(cmd.cfg.k),32'(cmd.scale_count_b),cmd.cfg.block_size==BLOCK16 ? 16 : 32) :
      (cmd.cfg.block_size==BLOCK16 ? 16 : 32);
    a_scale_index=0;b_scale_index=0;a_room=LANES;b_room=LANES;
    if (cmd.cfg.block_scale_en && a_span!=0 && b_span!=0) begin
      a_scale_index=(context_k[current_context]+32'(cmd.cfg.a_block_offset))/a_span;
      b_scale_index=(context_k[current_context]+32'(cmd.cfg.b_block_offset))/b_span;
      a_room=a_span-((context_k[current_context]+32'(cmd.cfg.a_block_offset))%a_span);
      b_room=b_span-((context_k[current_context]+32'(cmd.cfg.b_block_offset))%b_span);
    end
    next_count=LANES;
    if (next_count>32'(cmd.cfg.k)-context_k[current_context]) next_count=32'(cmd.cfg.k)-context_k[current_context];
    if (next_count>a_room) next_count=a_room;
    if (next_count>b_room) next_count=b_room;
    // The MALU interface independently forbids crossing either configured
    // BLOCK16/BLOCK32 boundary, even when a native scale vector spans more K.
    if (cmd.cfg.block_scale_en) begin
      if (next_count>(cmd.cfg.block_size==BLOCK16 ? 16 : 32)-
          ((context_k[current_context]+32'(cmd.cfg.a_block_offset))%(cmd.cfg.block_size==BLOCK16 ? 16 : 32)))
        next_count=(cmd.cfg.block_size==BLOCK16 ? 16 : 32)-
          ((context_k[current_context]+32'(cmd.cfg.a_block_offset))%(cmd.cfg.block_size==BLOCK16 ? 16 : 32));
      if (next_count>(cmd.cfg.block_size==BLOCK16 ? 16 : 32)-
          ((context_k[current_context]+32'(cmd.cfg.b_block_offset))%(cmd.cfg.block_size==BLOCK16 ? 16 : 32)))
        next_count=(cmd.cfg.block_size==BLOCK16 ? 16 : 32)-
          ((context_k[current_context]+32'(cmd.cfg.b_block_offset))%(cmd.cfg.block_size==BLOCK16 ? 16 : 32));
    end
    zero_column_shift=cmd.ws ? 32'(cmd.zero_column_mask_desc[61:56]) : 0;
    zero_b=zero_column(cmd,context_n[current_context]);
    shift_output_n=shift_copy==0 ? 0 : 32'(cmd.n)/2;
    d_location=mma_d_access(cmd,writing_back ? writeback_m : context_m[current_context],
      writing_back ? writeback_n : context_n[current_context]);
    d_disabled=cmd.disable_d_lanes[{d_location.peer,d_location.lane}];
  end

  task automatic abort_operation(input tc_status_e status,input malu_status_e numerical);
    response.status<=status;
    response.malu_status<=numerical;
    array_run<=0;
    context_live<='0;
    collector_a_valid[cmd.owner]<=0;
    for (int i=0;i<4;i++) collector_b_valid[cmd.owner][i]<=0;
    state<=M_RESPOND;
  endtask
  task automatic request_word(input tc_access_t address,input logic writing,
      input logic is_smem,input logic [31:0] value,input logic [3:0] strobes,
      input state_e after_memory);
    if (address.bad || (!is_smem && int'(address.col)>=COLS) ||
        (is_smem && address.byte_addr[1:0]!=0)) abort_operation(TC_RANGE,STATUS_OK);
    else if (memory_sequence==64'hffffffffffffffff) abort_operation(TC_SEQUENCE_EXHAUSTED,STATUS_OK);
    else begin
      memory_sequence<=memory_sequence+1;
      memory_request<='0;
      memory_request.write<=writing;
      memory_request.owner<=address.peer ? cmd.peer_owner : cmd.owner;
      memory_request.owner_generation<=address.peer ? cmd.peer_generation : cmd.owner_generation;
      memory_request.peer<=address.peer;
      memory_request.byte_addr<=address.byte_addr;
      memory_request.lane<=address.lane;
      memory_request.col<=address.col;
      memory_request.wdata<=value;
      memory_request.wstrb<=strobes;
      memory_request.txn_id<=memory_sequence+1;
      memory_is_smem<=is_smem;
      mem_return<=after_memory;
      state<=M_MEM_SEND;
    end
  endtask
  task automatic read_element(input tc_access_t address,input logic is_smem,
      input int unsigned width,input state_e after_read);
    if (width<1 || width>64) abort_operation(TC_BAD_CMD,STATUS_BAD_CFG);
    else begin
      read_origin<=address;read_is_smem<=is_smem;
      read_width<=width;read_index<=0;
      read_words<=(32'(address.bit_offset)+width+31)>>5;
      read_buffer<=0;
      read_return<=after_read;
      request_word(address,0,is_smem,0,0,M_READ_CAPTURE);
    end
  endtask
  task automatic captured_a;
    logical_a_captured<=logical_a_captured+1;
    if (logical_k+1==32'(cmd.cfg.k)) begin
      a_dots_captured<=a_dots_captured+1;
      if (!cmd.a_from_tmem && all_created && a_dots_captured+1==total_dots) aread_done<=1;
    end
  endtask
  task automatic finish_dot;
    if (writeback_index+1==total_dots) state<=cmd.ashift ? M_ASHIFT_BEGIN : M_FINISH;
    else begin
      writeback_index<=writeback_index+1;
      if (writeback_n+1==32'(cmd.n)) begin writeback_n<=0;writeback_m<=writeback_m+1;end
      else writeback_n<=writeback_n+1;
      state<=M_WRITEBACK_FETCH;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state<=M_IDLE;mem_return<=M_IDLE;read_return<=M_IDLE;
      cmd<='0;response<='0;context_live<='0;
      current_context<=0;probe_context<=0;
      next_m<=0;next_n<=0;all_created<=0;
      completed_dots<=0;total_dots<=0;logical_a_captured<=0;a_dots_captured<=0;
      writing_back<=0;writeback_index<=0;writeback_m<=0;writeback_n<=0;
      array_run<=0;aread_done<=0;
      beat_count<=0;lane_slot<=0;beat_a<='0;beat_b<='0;scale_a<=0;scale_b<=0;d_value<=0;
      memory_request<='0;read_origin<='0;memory_is_smem<=0;read_is_smem<=0;
      memory_sequence<=0;memory_data<=0;read_buffer<=0;read_value<=0;
      read_width<=1;read_index<=0;read_words<=1;
      shift_row<=0;shift_word<=0;shift_words<=0;shift_copy<=0;shift_copies<=1;shift_data<=0;
      for (int i=0;i<DOT_ENGINES;i++) begin
        context_m[i]<=0;context_n[i]<=0;context_k[i]<=0;context_c[i]<=0;
        context_result_index[i]<=0;
        context_meta_valid[i]<=0;context_meta_group[i]<=0;context_meta[i]<=0;
      end
      for (int o=0;o<TC_OWNERS;o++) begin
        collector_a_valid[o]<=0;collector_a_generation[o]<=0;
        for (int b=0;b<4;b++) begin collector_b_valid[o][b]<=0;collector_b_generation[o][b]<=0;end
      end
    end else begin
      aread_done<=0;
      case (state)
        M_IDLE: begin
          array_run<=0;
          if (req_valid) begin
            cmd<=req;response<=response_for(req,TC_OK);
            context_live<='0;next_m<=0;next_n<=0;all_created<=0;
            completed_dots<=0;logical_a_captured<=0;total_dots<=0;a_dots_captured<=0;
            writing_back<=0;writeback_index<=0;writeback_m<=0;writeback_n<=0;
            probe_context<=0;state<=M_VALIDATE;
          end
        end
        M_VALIDATE: begin
          if (cmd.op!=TC_MMA || cmd.m==0 || cmd.n==0 || int'(cmd.m)>MAX_M ||
              int'(cmd.n)>MAX_N || cfg_status(cmd.cfg,MAX_K,ENABLE_FP64)!=STATUS_OK)
            abort_operation(TC_BAD_CMD,cfg_status(cmd.cfg,MAX_K,ENABLE_FP64));
          else if (cmd.enable_input_d &&
              ((cmd.cfg.c_fmt==FMT_F64)!=(cmd.cfg.d_fmt==FMT_F64)))
            // The same in-place D object supplies C. Expanding its word stride
            // could overwrite an old C value before that dot captures it.
            abort_operation(TC_UNSUPPORTED,STATUS_OK);
          else if ((cmd.collector_a inside {TC_COLLECT_USE,TC_COLLECT_LASTUSE}) &&
              (!collector_a_valid[cmd.owner] || collector_a_generation[cmd.owner]!=cmd.owner_generation))
            abort_operation(TC_ORDER,STATUS_OK);
          else if ((cmd.collector_b inside {TC_COLLECT_USE,TC_COLLECT_LASTUSE}) &&
              (!collector_b_valid[cmd.owner][cmd.collector_b_id] ||
               collector_b_generation[cmd.owner][cmd.collector_b_id]!=cmd.owner_generation))
            abort_operation(TC_ORDER,STATUS_OK);
          else if (cmd.ashift && (!cmd.a_from_tmem || cmd.transpose_a || !(cmd.m inside {128,256}) ||
              cmd.collector_a inside {TC_COLLECT_USE,TC_COLLECT_FILL}))
            abort_operation(TC_BAD_CMD,STATUS_OK);
          else begin array_run<=1;state<=M_RUN;end
        end
        M_RUN: begin
          if (array_rsp_valid) begin
            if (response_context>=DOT_ENGINES || !context_live[response_context])
              abort_operation(TC_ORDER,STATUS_OK);
            else if (array_rsp_status!=STATUS_OK) abort_operation(TC_MALU_ERROR,array_rsp_status);
            else if (context_k[response_context]!=32'(cmd.cfg.k)) abort_operation(TC_ORDER,STATUS_LENGTH);
            else begin
              result_low[context_result_index[response_context]]<=array_rsp_data[31:0];
              if (ENABLE_FP64) result_high[context_result_index[response_context]]<=array_rsp_data[63:32];
              context_live[response_context]<=0;
              completed_dots<=completed_dots+1;
            end
          end else if (!all_created && free_context>=0) begin
            current_context<=free_context;
            context_live[free_context]<=1;
            total_dots<=total_dots+1;
            context_result_index[free_context]<=total_dots;
            context_m[free_context]<=next_m;context_n[free_context]<=next_n;
            context_k[free_context]<=0;context_c[free_context]<=0;
            context_meta_valid[free_context]<=0;
            if (next_n+1==32'(cmd.n)) begin
              next_n<=0;next_m<=next_m+1;
              if (next_m+1==32'(cmd.m)) all_created<=1;
            end else next_n<=next_n+1;
            state<=M_BEGIN_DOT;
          end else if (completed_dots==total_dots && all_created) begin
            writing_back<=1;writeback_index<=0;writeback_m<=0;writeback_n<=0;
            state<=M_WRITEBACK_FETCH;
          end
          else if (context_live[probe_context] && context_k[probe_context]<32'(cmd.cfg.k) && array_op_ready) begin
            current_context<=probe_context;
            probe_context<=probe_context==DOT_ENGINES-1 ? 0 : probe_context+1;
            state<=M_PREP_BEAT;
          end else probe_context<=probe_context==DOT_ENGINES-1 ? 0 : probe_context+1;
        end
        M_BEGIN_DOT: begin
          if (cmd.enable_input_d)
            read_element(d_location,0,fmt_width(cmd.cfg.c_fmt),M_C_CAPTURE);
          else state<=M_SEND_DESC;
        end
        M_C_CAPTURE: begin context_c[current_context]<=read_value;state<=M_SEND_DESC;end
        M_SEND_DESC: if (array_req_ready) state<=M_RUN;
        M_PREP_BEAT: begin
          beat_a<='0;beat_b<='0;lane_slot<=0;beat_count<=next_count;scale_a<=0;scale_b<=0;
          if (next_count==0) abort_operation(TC_BAD_CMD,STATUS_LENGTH);
          else state<=cmd.cfg.block_scale_en ? M_SCALE_A : M_GET_A;
        end
        M_SCALE_A: read_element(mma_scale_a_access(cmd,context_m[current_context],a_scale_index),
          cmd.recipe==TC_RECIPE_WORD32_REF,8,M_SCALE_A_CAPTURE);
        M_SCALE_A_CAPTURE: begin scale_a<=read_value[7:0];state<=M_SCALE_B;end
        M_SCALE_B: read_element(mma_scale_b_access(cmd,context_n[current_context],b_scale_index),
          cmd.recipe==TC_RECIPE_WORD32_REF,8,M_SCALE_B_CAPTURE);
        M_SCALE_B_CAPTURE: begin scale_b<=read_value[7:0];state<=M_GET_A;end
        M_GET_A: begin
          if (cmd.sparse && (!context_meta_valid[current_context] || context_meta_group[current_context]!=sparse_group))
            read_element(mma_meta_access(cmd,context_m[current_context],sparse_group,context_n[current_context]),0,4,M_META_CAPTURE);
          else if (cmd.sparse && !metadata_valid) abort_operation(TC_BAD_CMD,STATUS_BAD_ENCODING);
          else if (!a_present) begin
            beat_a[lane_slot]<=negate_value(0,cmd.cfg.a_fmt,cmd.negate_a);
            captured_a();state<=M_GET_B;
          end else read_element(mma_a_access(cmd,context_m[current_context],stored_k,context_n[current_context]),
            !cmd.a_from_tmem,fmt_width(cmd.cfg.a_fmt),M_A_CAPTURE);
        end
        M_META_CAPTURE: begin
          context_meta[current_context]<=read_value[3:0];
          context_meta_group[current_context]<=sparse_group;context_meta_valid[current_context]<=1;
          state<=M_GET_A;
        end
        M_A_CAPTURE: begin
          beat_a[lane_slot]<=negate_value(read_value,cmd.cfg.a_fmt,cmd.negate_a);
          captured_a();state<=M_GET_B;
        end
        M_GET_B: begin
          if (zero_b) begin beat_b[lane_slot]<=negate_value(0,cmd.cfg.b_fmt,cmd.negate_b);state<=M_ELEMENT_NEXT;end
          else read_element(mma_b_access(cmd,logical_k,context_n[current_context]+zero_column_shift),
            1,cmd.lut ? 3 : fmt_width(cmd.cfg.b_fmt),M_B_CAPTURE);
        end
        M_B_CAPTURE: begin
          if (cmd.lut) read_element(mma_lut_access(cmd,context_n[current_context],32'(read_value[2:0])),0,8,M_LUT_CAPTURE);
          else begin beat_b[lane_slot]<=negate_value(read_value,cmd.cfg.b_fmt,cmd.negate_b);state<=M_ELEMENT_NEXT;end
        end
        M_LUT_CAPTURE: begin beat_b[lane_slot]<=negate_value(read_value,cmd.cfg.b_fmt,cmd.negate_b);state<=M_ELEMENT_NEXT;end
        M_ELEMENT_NEXT: begin
          if (lane_slot+1==beat_count) state<=M_SEND_BEAT;
          else begin lane_slot<=lane_slot+1;state<=M_GET_A;end
        end
        M_SEND_BEAT: if (array_op_ready) begin
          context_k[current_context]<=context_k[current_context]+beat_count;
          state<=M_RUN;
        end
        M_WRITEBACK_FETCH: begin
          d_value[31:0]<=result_low[writeback_index];
          if (ENABLE_FP64) d_value[63:32]<=result_high[writeback_index];
          else d_value[63:32]<=0;
          state<=M_D_WRITE;
        end
        M_D_WRITE: begin
          if (d_location.bad) abort_operation(TC_RANGE,STATUS_OK);
          else if (d_disabled) finish_dot();
          else if (d_location.bit_offset!=0) abort_operation(TC_BAD_CMD,STATUS_BAD_CFG);
          else request_word(d_location,1,0,d_value[31:0],
            (cmd.cfg.d_fmt inside {FMT_F16,FMT_BF16}) && cmd.recipe!=TC_RECIPE_WORD32_REF ? 4'h3 : 4'hf,
            cmd.cfg.d_fmt==FMT_F64 ? M_D_HIGH : M_D_FINISH);
        end
        M_D_HIGH: request_word(tc_word_advance(cmd,d_location,1,0),1,0,d_value[63:32],4'hf,M_D_FINISH);
        M_D_FINISH: finish_dot();
        M_ASHIFT_BEGIN: begin : begin_shift
          tc_access_t first,last;
          int unsigned count;
          first=mma_a_access(cmd,0,0);
          last=mma_a_access(cmd,0,(cmd.sparse ? 32'(cmd.cfg.k)>>1 : 32'(cmd.cfg.k))-1);
          count=cmd.recipe==TC_RECIPE_WORD32_REF ?
            ((32'(last.col)-32'(first.col))<<7)+32'(last.lane)-32'(first.lane)+((32'(last.bit_offset)+fmt_width(cmd.cfg.a_fmt)+31)>>5) :
            32'(last.col)-32'(first.col)+((32'(last.bit_offset)+fmt_width(cmd.cfg.a_fmt)+31)>>5);
          if (first.bad || last.bad || count==0 || count>8192) abort_operation(TC_RANGE,STATUS_OK);
          else begin
            shift_words<=count;shift_row<=0;shift_word<=0;shift_copy<=0;
            shift_copies<=cmd.recipe==TC_RECIPE_NATIVE && cmd.cta_pair && cmd.m==128 && !cmd.sparse ? 2 : 1;
            state<=M_ASHIFT_READ;
          end
        end
        M_ASHIFT_READ: read_element(tc_word_advance(cmd,mma_a_access(cmd,shift_row+1,0,shift_output_n),shift_word,0),0,32,M_ASHIFT_WRITE);
        M_ASHIFT_WRITE: begin
          shift_data<=read_value[31:0];
          request_word(tc_word_advance(cmd,mma_a_access(cmd,shift_row,0,shift_output_n),shift_word,0),1,0,read_value[31:0],4'hf,M_ASHIFT_NEXT);
        end
        M_ASHIFT_NEXT: begin
          if (shift_word+1<shift_words) begin shift_word<=shift_word+1;state<=M_ASHIFT_READ;end
          else if (shift_row+2<32'(cmd.m)) begin shift_word<=0;shift_row<=shift_row+1;state<=M_ASHIFT_READ;end
          else if (shift_copy+1<shift_copies) begin
            shift_copy<=shift_copy+1;shift_word<=0;shift_row<=0;state<=M_ASHIFT_READ;
          end
          else state<=M_FINISH;
        end
        M_READ_CAPTURE: begin
          read_buffer<=read_merged;
          if (read_index+1==read_words) begin
            read_value<=64'(read_merged>>read_origin.bit_offset)&width_mask(read_width);
            state<=read_return;
          end else begin
            read_index<=read_index+1;
            request_word(tc_word_advance(cmd,read_origin,read_index+1,read_is_smem),0,read_is_smem,0,0,M_READ_CAPTURE);
          end
        end
        M_MEM_SEND: if (memory_is_smem ? smem_req_ready : tm_req_ready) state<=M_MEM_WAIT;
        M_MEM_WAIT: begin
          if (memory_is_smem && smem_rsp_valid && smem_rsp.txn_id==memory_request.txn_id) begin
            if (smem_rsp.status!=TC_OK) abort_operation(TC_MEM_ERROR,STATUS_OK);
            else begin memory_data<=smem_rsp.rdata;state<=mem_return;end
          end else if (!memory_is_smem && tm_rsp_valid && tm_rsp.txn_id==memory_request.txn_id) begin
            if (tm_rsp.status!=TC_OK) abort_operation(TC_MEM_ERROR,STATUS_OK);
            else begin memory_data<=tm_rsp.rdata;state<=mem_return;end
          end
        end
        M_FINISH: begin
          collector_a_valid[cmd.owner]<=cmd.collector_a inside {TC_COLLECT_FILL,TC_COLLECT_USE};
          collector_a_generation[cmd.owner]<=cmd.owner_generation;
          collector_b_valid[cmd.owner][cmd.collector_b_id]<=cmd.collector_b inside {TC_COLLECT_FILL,TC_COLLECT_USE};
          collector_b_generation[cmd.owner][cmd.collector_b_id]<=cmd.owner_generation;
          array_run<=0;state<=M_RESPOND;
        end
        M_RESPOND: if (rsp_ready) state<=M_IDLE;
        default: abort_operation(TC_BAD_CMD,STATUS_OK);
      endcase
    end
  end
`ifdef TCGEN05_ASSERTIONS
  assert property (@(posedge clk) disable iff (!rst_n)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp));
  assert property (@(posedge clk) disable iff (!rst_n)
    tm_req_valid && !tm_req_ready |=> tm_req_valid && $stable(tm_req));
  assert property (@(posedge clk) disable iff (!rst_n)
    smem_req_valid && !smem_req_ready |=> smem_req_valid && $stable(smem_req));
  assert property (@(posedge clk) disable iff (!rst_n)
    aread_done |-> !cmd.a_from_tmem && all_created && a_dots_captured==total_dots);
`endif
endmodule

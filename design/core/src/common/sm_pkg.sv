package sm_pkg;
  // Versioned project IR/control transport, never NVIDIA binary encoding.
  localparam int SM_IR_VERSION=1;
  localparam int SM_THREADS=32;
  localparam int SM_MAX_WARPS=64;
  localparam int SM_GPRS=256;
  localparam int SM_PREDS=8;
  localparam int SM_SRC_SPANS=4;
  localparam int SM_DST_SPANS=3;
  localparam int SM_EXEC_COUNT=15;
  typedef enum logic [3:0] {
    SM_EX_SALU=0,SM_EX_VALU_INT=1,SM_EX_FMA=2,SM_EX_SFU=3,
    SM_EX_CVT=4,SM_EX_LSU=5,SM_EX_MOVE=6,SM_EX_TMA=7,
    SM_EX_TENSOR=8,SM_EX_SYNC=9,SM_EX_WARP=10,SM_EX_TEX=11,
    SM_EX_FABRIC=12,SM_EX_SYSTEM=13,SM_EX_FP64=14
  } sm_exec_e;
  typedef enum logic [2:0] {
    SM_OP_EXEC=0,SM_OP_NOP=1,SM_OP_BRA=2,SM_OP_WAIT=3,SM_OP_EXIT=4
  } sm_opcode_e;
  typedef enum logic [1:0] {SM_RF_NONE=0,SM_RF_GPR=1,SM_RF_PRED=2,SM_RF_CC=3} sm_rf_e;
  typedef enum logic [3:0] {
    SM_OK=0,SM_BAD_WARP=1,SM_BAD_CONTEXT=2,SM_BUSY=3,SM_BAD_IR=4,
    SM_UNSUPPORTED=5,SM_SEQUENCE_EXHAUSTED=6,SM_EXEC_ERROR=7,SM_PROTOCOL=8
  } sm_status_e;
  typedef enum logic [1:0] {SM_W_FREE=0,SM_W_RUN=1,SM_W_EXITED=2,SM_W_FAULT=3} sm_warp_state_e;
  typedef struct packed {
    sm_rf_e kind;
    logic [7:0] base;
    logic [8:0] count;
  } sm_span_t;
  typedef struct packed {
    sm_opcode_e op;
    sm_exec_e unit_id;
    logic [15:0] function_id;
    logic uniform_proven;
    logic [31:0] lane_mask;
    sm_span_t [SM_SRC_SPANS-1:0] src;
    sm_span_t [SM_DST_SPANS-1:0] dst;
    logic [63:0] immediate;
    logic [31:0] branch_target;
  } sm_instr_t;
  typedef struct packed {
    logic [31:0] epoch;
    logic [2:0] owner;
    logic [15:0] generation;
    logic [5:0] warp;
    logic [31:0] pc;
    sm_instr_t instr;
  } sm_fetch_t;
  typedef struct packed {
    logic [31:0] epoch;
    logic [2:0] owner;
    logic [15:0] generation;
    logic [5:0] warp;
    logic [31:0] pc;
    sm_status_e status;
  } sm_fetch_rsp_t;
  typedef struct packed {
    logic [31:0] epoch;
    logic [31:0] ticket;
    logic [2:0] owner;
    logic [15:0] generation;
    logic [5:0] warp;
    logic [31:0] instance_id;
  } sm_token_t;
  typedef struct packed {
    sm_token_t token;
    logic [31:0] pc;
    sm_instr_t instr;
  } sm_issue_t;
  typedef struct packed {
    sm_token_t token;
    sm_status_e status;
    // Success with register destinations is legal only after every required
    // GPR/predicate/CC write has committed, not just entered a result FIFO.
    logic writes_committed;
  } sm_complete_t;
  typedef struct packed {
    logic [255:0] gpr;
    logic [7:0] pred;
    logic cc;
  } sm_reg_mask_t;
  typedef struct packed {
    logic [31:0] epoch;
    logic detach;
    logic [15:0] tag;
    logic [2:0] owner;
    logic [15:0] generation;
    logic [5:0] warp;
    logic [31:0] entry_pc;
    logic [31:0] active_mask;
  } sm_warp_cmd_t;
  typedef struct packed {
    logic [31:0] epoch;
    logic [15:0] tag;
    logic [5:0] warp;
    logic [2:0] owner;
    logic [15:0] generation;
    sm_status_e status;
  } sm_warp_rsp_t;

  function automatic logic span_valid(input sm_span_t s);
    case(s.kind)
      SM_RF_NONE:return s.base==0 && s.count==0;
      SM_RF_GPR:return s.count!=0 && 32'(s.base)+32'(s.count)<=SM_GPRS;
      SM_RF_PRED:return s.count!=0 && 32'(s.base)+32'(s.count)<=SM_PREDS;
      SM_RF_CC:return s.base==0 && s.count==1;
      default:return 0;
    endcase
  endfunction
  function automatic sm_reg_mask_t span_mask(input sm_span_t s);
    sm_reg_mask_t m;
    m='0;
    if(span_valid(s)) begin
      for(int i=0;i<SM_GPRS;i++)
        if(s.kind==SM_RF_GPR && i>=32'(s.base) && i<32'(s.base)+32'(s.count))m.gpr[i]=1;
      for(int i=0;i<SM_PREDS;i++)
        if(s.kind==SM_RF_PRED && i>=32'(s.base) && i<32'(s.base)+32'(s.count))m.pred[i]=1;
      m.cc=s.kind==SM_RF_CC;
    end
    return m;
  endfunction
  function automatic sm_reg_mask_t source_mask(input sm_instr_t ins);
    sm_reg_mask_t m;m='0;
    for(int i=0;i<SM_SRC_SPANS;i++)m=m|span_mask(ins.src[i]);
    return m;
  endfunction
  function automatic sm_reg_mask_t destination_mask(input sm_instr_t ins);
    sm_reg_mask_t m;m='0;
    for(int i=0;i<SM_DST_SPANS;i++)m=m|span_mask(ins.dst[i]);
    return m;
  endfunction
  function automatic logic spans_valid(input sm_instr_t ins);
    for(int i=0;i<SM_SRC_SPANS;i++)if(!span_valid(ins.src[i]))return 0;
    for(int i=0;i<SM_DST_SPANS;i++)if(!span_valid(ins.dst[i]))return 0;
    return 1;
  endfunction
endpackage

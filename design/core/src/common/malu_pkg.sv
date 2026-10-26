package malu_pkg;
  // The implemented numerical contract is PROJECT_EXACT, not a GPU device fit.
  typedef enum logic [4:0] {
    FMT_F16=0, FMT_BF16=1, FMT_TF32=2, FMT_F32=3, FMT_F64=4,
    FMT_E4M3=5, FMT_E5M2=6, FMT_E2M3=7, FMT_E3M2=8, FMT_E2M1=9,
    FMT_S8=10, FMT_U8=11, FMT_S4=12, FMT_U4=13, FMT_TI16=14,
    FMT_B1=15, FMT_S32=16,
    // Internal decoder selectors: these are not ordinary A/B data formats.
    FMT_UE8M0=17, FMT_UE4M3=18, FMT_UE5M3=19, FMT_INVALID=31
  } malu_fmt_e;
  typedef enum logic [1:0] {
    SCALE_NONE=0, SCALE_UE8M0=1, SCALE_UE4M3=2, SCALE_UE5M3=3
  } malu_scale_e;
  typedef enum logic [1:0] {
    ROUND_RNE=0, ROUND_RTZ=1, ROUND_RDN=2, ROUND_RUP=3
  } malu_round_e;
  typedef enum logic { BLOCK16=0, BLOCK32=1 } malu_block_e;
  typedef enum logic [3:0] {
    STATUS_OK=0, STATUS_BAD_CFG=1, STATUS_BAD_ENCODING=2,
    STATUS_LENGTH=3, STATUS_UNSUPPORTED=4, STATUS_RANGE=5
  } malu_status_e;
  localparam logic [1:0] PROJECT_EXACT = 2'd0;
  localparam int MUL_BITS = 53;
  localparam int WORD_BITS = 32;
  localparam int FULL_ACC_BASE = -2148;
  localparam int FULL_ACC_WORDS = 132;
  localparam int LOW_ACC_BASE = -300;
  localparam int LOW_ACC_WORDS = 20;

  typedef struct packed {
    logic sign;
    logic is_zero;
    logic is_inf;
    logic is_nan;
    logic bad;
    logic [52:0] sig;
    logic signed [15:0] exp;
  } malu_dec_t;

  typedef struct packed {
    malu_fmt_e a_fmt;
    malu_fmt_e b_fmt;
    malu_fmt_e c_fmt;
    malu_fmt_e d_fmt;
    malu_scale_e a_scale_fmt;
    malu_scale_e b_scale_fmt;
    logic block_scale_en;
    malu_block_e block_size;
    logic [4:0] a_block_offset;
    logic [4:0] b_block_offset;
    logic [15:0] k;
    malu_round_e rounding;
    logic int_sat;
    logic binary_xor;
    // 1 means project-defined decoded two's-complement integer transport.
    // 0 requests unspecified PTX raw S1Z4M11 encoding and must be rejected.
    logic ti16_decoded;
    logic [3:0] c_scale_shift;
    logic [1:0] profile;
  } malu_cfg_t;

  function automatic logic is_fp(input malu_fmt_e f);
    return f inside {FMT_F16,FMT_BF16,FMT_TF32,FMT_F32,FMT_F64,
                     FMT_E4M3,FMT_E5M2,FMT_E2M3,FMT_E3M2,FMT_E2M1};
  endfunction
  function automatic logic is_low_fp(input malu_fmt_e f);
    return f inside {FMT_E4M3,FMT_E5M2,FMT_E2M3,FMT_E3M2,FMT_E2M1};
  endfunction
  function automatic logic is_fp_result(input malu_fmt_e f);
    return f inside {FMT_F16,FMT_BF16,FMT_F32,FMT_F64};
  endfunction
  function automatic logic is_int(input malu_fmt_e f);
    return f inside {FMT_S8,FMT_U8,FMT_S4,FMT_U4,FMT_TI16,FMT_B1};
  endfunction
  function automatic int unsigned fmt_width(input malu_fmt_e f);
    case (f)
      FMT_F16,FMT_BF16,FMT_TI16: return 16;
      FMT_TF32,FMT_F32,FMT_S32: return 32;
      FMT_F64: return 64;
      FMT_E4M3,FMT_E5M2,FMT_S8,FMT_U8,FMT_UE8M0,FMT_UE5M3: return 8;
      FMT_UE4M3: return 7;
      FMT_E2M3,FMT_E3M2: return 6;
      FMT_E2M1,FMT_S4,FMT_U4: return 4;
      FMT_B1: return 1;
      default: return 0;
    endcase
  endfunction
  function automatic int unsigned fmt_exp_bits(input malu_fmt_e f);
    case (f)
      FMT_F16,FMT_E5M2,FMT_UE5M3: return 5;
      FMT_BF16,FMT_TF32,FMT_F32,FMT_UE8M0: return 8;
      FMT_F64: return 11;
      FMT_E4M3,FMT_UE4M3: return 4;
      FMT_E2M3,FMT_E2M1: return 2;
      FMT_E3M2: return 3;
      default: return 0;
    endcase
  endfunction
  function automatic int unsigned fmt_frac_bits(input malu_fmt_e f);
    case (f)
      FMT_F16,FMT_TF32: return 10;
      FMT_BF16: return 7;
      FMT_F32: return 23;
      FMT_F64: return 52;
      FMT_E4M3,FMT_E2M3,FMT_UE4M3,FMT_UE5M3: return 3;
      FMT_E5M2,FMT_E3M2: return 2;
      FMT_E2M1: return 1;
      default: return 0;
    endcase
  endfunction
  function automatic int signed fmt_bias(input malu_fmt_e f);
    case (f)
      FMT_F16,FMT_E5M2,FMT_UE5M3: return 15;
      FMT_BF16,FMT_TF32,FMT_F32,FMT_UE8M0: return 127;
      FMT_F64: return 1023;
      FMT_E4M3,FMT_UE4M3: return 7;
      FMT_E2M3,FMT_E2M1: return 1;
      FMT_E3M2: return 3;
      default: return 0;
    endcase
  endfunction
  function automatic logic fmt_has_inf(input malu_fmt_e f);
    return f inside {FMT_F16,FMT_BF16,FMT_TF32,FMT_F32,FMT_F64,FMT_E5M2};
  endfunction
  function automatic malu_fmt_e scale_to_fmt(input malu_scale_e s);
    case (s)
      SCALE_UE8M0: return FMT_UE8M0;
      SCALE_UE4M3: return FMT_UE4M3;
      SCALE_UE5M3: return FMT_UE5M3;
      default: return FMT_INVALID;
    endcase
  endfunction

  function automatic malu_status_e cfg_status(
      input malu_cfg_t c, input int unsigned max_k,
      input logic enable_fp64);
    int unsigned block_len;
    if (c.profile != PROJECT_EXACT) return STATUS_UNSUPPORTED;
    if (c.k == 0 || int'(c.k) > max_k) return STATUS_LENGTH;
    if (!enable_fp64 && (c.a_fmt == FMT_F64 || c.b_fmt == FMT_F64 ||
                         c.c_fmt == FMT_F64 || c.d_fmt == FMT_F64))
      return STATUS_UNSUPPORTED;
    if (is_fp(c.a_fmt) && is_fp(c.b_fmt)) begin
      if (!is_fp_result(c.c_fmt) || !is_fp_result(c.d_fmt)) return STATUS_BAD_CFG;
      if (c.int_sat || c.binary_xor) return STATUS_BAD_CFG;
      if (c.c_scale_shift != 0 &&
          !((c.a_fmt inside {FMT_F16,FMT_BF16}) &&
            (c.b_fmt inside {FMT_F16,FMT_BF16})) &&
          !(c.a_fmt == FMT_TF32 && c.b_fmt == FMT_TF32)) return STATUS_BAD_CFG;
      if (c.block_scale_en) begin
        if (!is_low_fp(c.a_fmt) || !is_low_fp(c.b_fmt)) return STATUS_BAD_CFG;
        if (c.a_scale_fmt == SCALE_NONE || c.a_scale_fmt != c.b_scale_fmt)
          return STATUS_BAD_CFG;
        block_len = (c.block_size == BLOCK16) ? 16 : 32;
        if (int'(c.a_block_offset) >= block_len ||
            int'(c.b_block_offset) >= block_len) return STATUS_BAD_CFG;
        if (c.block_size == BLOCK16 || c.a_scale_fmt != SCALE_UE8M0)
          if (c.a_fmt != FMT_E2M1 || c.b_fmt != FMT_E2M1) return STATUS_BAD_CFG;
      end
      return STATUS_OK;
    end
    if (is_int(c.a_fmt) && is_int(c.b_fmt)) begin
      if (c.c_fmt != FMT_S32 || c.d_fmt != FMT_S32 || c.block_scale_en ||
          c.c_scale_shift != 0) return STATUS_BAD_CFG;
      if (fmt_width(c.a_fmt) != fmt_width(c.b_fmt)) return STATUS_BAD_CFG;
      if (c.a_fmt == FMT_TI16 || c.b_fmt == FMT_TI16) begin
        if (c.a_fmt != FMT_TI16 || c.b_fmt != FMT_TI16 || c.int_sat)
          return STATUS_BAD_CFG;
        if (!c.ti16_decoded) return STATUS_UNSUPPORTED;
      end
      if (c.a_fmt == FMT_B1 || c.b_fmt == FMT_B1) begin
        if (c.a_fmt != FMT_B1 || c.b_fmt != FMT_B1 || c.int_sat)
          return STATUS_BAD_CFG;
      end else if (c.binary_xor) return STATUS_BAD_CFG;
      return STATUS_OK;
    end
    return STATUS_BAD_CFG;
  endfunction
endpackage

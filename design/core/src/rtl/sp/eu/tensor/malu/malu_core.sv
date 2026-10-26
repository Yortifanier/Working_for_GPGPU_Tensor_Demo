// Low-area PROJECT_EXACT dot engine. One unsigned 53x53 multiplier, one shared
// 32-bit data adder, and one single-port word RAM. No real/shortreal arithmetic.
module malu_core #(
  parameter int LANES = 4,
  parameter int TAG_W = 8,
  parameter int MAX_K = 65535,
  parameter bit ENABLE_FP64 = 1
) (
  input logic clk, rst_n,
  input logic req_valid,
  output logic req_ready,
  input malu_pkg::malu_cfg_t req_cfg,
  input logic [63:0] req_c,
  input logic [TAG_W-1:0] req_tag,
  input logic op_valid,
  output logic op_ready,
  input logic [LANES-1:0][63:0] op_a, op_b,
  input logic [$clog2(LANES+1)-1:0] op_count,
  input logic [7:0] op_scale_a, op_scale_b,
  input logic op_last,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [63:0] rsp_data,
  output logic [TAG_W-1:0] rsp_tag,
  output malu_pkg::malu_status_e rsp_status
);
  import malu_pkg::*;
  typedef enum logic [5:0] {
    IDLE, CLEAR, DECODE_C, DECODE_A, DECODE_B, DECODE_SA, DECODE_SB,
    DECODE_ABS, PREPARE, MUL_A_SCALE, MUL_B_SCALE, MUL_AB, NEXT_ITEM,
    WAIT_BEAT, ACC_READ, ACC_WRITE, SIGN_READ, SIGN_TEST, ABS_READ,
    ABS_WRITE, MSB_READ, MSB_TEST, GATHER_READ, GATHER_TEST, ROUND_DECIDE,
    ROUND_LOW, ROUND_HIGH, PACK, INT_FINISH, INT_NEGATE, RESPOND
  } state_e;
  state_e state, term_return, abs_return;
  // profile is checked on request acceptance; the latched copy is metadata.
  malu_cfg_t cfg;
  logic [63:0] c_bits;
  logic integer_mode;
  logic [LANES-1:0][63:0] a_cache, b_cache;
  logic [7:0] sa_bits, sb_bits;
  integer lane_index, beat_count;
  logic beat_last;
  logic [16:0] accepted_k;
  // Stored bad bits are intentionally unused: decoded.bad is checked before
  // execution. Scale sign bits are unused because all scale types are unsigned.
  malu_dec_t da, db, dsa, dsb, decoded;
  logic decode_abs;
  logic [63:0] decode_raw;
  malu_fmt_e decode_fmt;
  logic [1:0] abs_destination;
  logic [31:0] abs_integer_bits;
  localparam int SHARED_MUL_W = ENABLE_FP64 ? 53 : 24;
  logic [52:0] a_sig, b_sig;
  logic [SHARED_MUL_W-1:0] mul_lhs, mul_rhs;
  logic [2*SHARED_MUL_W-1:0] shared_product;
  logic signed [15:0] a_exp, b_exp;
  logic [105:0] mul_product;
  localparam int RAM_WORDS = ENABLE_FP64 ? FULL_ACC_WORDS : LOW_ACC_WORDS;
  logic [31:0] acc_ram [0:RAM_WORDS-1];
  logic [31:0] ram_data;
  integer active_words, acc_base, word_index;
  integer term_start;
  logic [137:0] term_window;
  logic term_negative, carry;
  logic [31:0] chunk, add_lhs, add_rhs;
  logic add_cin;
  logic [32:0] add_result;
  logic saw_nan, saw_pos_inf, saw_neg_inf;
  logic zero_all_negative, zero_all_positive;
  logic magnitude_negative;
  integer cut_bit;
  logic [53:0] round_sig;
  logic guard_bit, round_bit, sticky_bit;
  logic pack_nan, pack_inf, pack_zero, pack_sign;
  logic signed [15:0] quant_exp;
  logic [63:0] packed_data;
  logic [31:0] integer_low;
  integer lead, exponent_high, precision, min_quant, chosen_quant;
  integer block_len, a_room, b_room, new_count;
  logic a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
  logic product_sign, increment_round, int_overflow;

  malu_decode decoder(.raw(decode_raw),.fmt(decode_fmt),
    .ti16_decoded(cfg.ti16_decoded),.dec(decoded),.needs_abs(decode_abs));
  malu_round_pack encoder(.fmt(cfg.d_fmt),.rounding(cfg.rounding),
    .sign(pack_sign),.is_nan(pack_nan),.is_inf(pack_inf),.is_zero(pack_zero),
    .rounded_sig(round_sig),.quant_exp(quant_exp),.data(packed_data));

  assign req_ready = state == IDLE;
  assign op_ready = state == WAIT_BEAT;
  assign rsp_valid = state == RESPOND;
  // The only variable-width numerical multiplication in the DUT.
  assign shared_product = mul_lhs * mul_rhs;
  assign mul_product = 106'(shared_product);
  // Carry-in is shared by limb add/subtract, magnitude, integer and rounding.
  assign add_result = {1'b0,add_lhs}+{1'b0,add_rhs}+{32'b0,add_cin};

  always_comb begin
    decode_raw = 0;
    decode_fmt = FMT_INVALID;
    case (state)
      DECODE_C: begin decode_raw=c_bits; decode_fmt=cfg.c_fmt; end
      DECODE_A: begin decode_raw=a_cache[lane_index]; decode_fmt=cfg.a_fmt; end
      DECODE_B: begin decode_raw=b_cache[lane_index]; decode_fmt=cfg.b_fmt; end
      DECODE_SA: begin decode_raw={56'b0,sa_bits}; decode_fmt=scale_to_fmt(cfg.a_scale_fmt); end
      DECODE_SB: begin decode_raw={56'b0,sb_bits}; decode_fmt=scale_to_fmt(cfg.b_scale_fmt); end
      default: ;
    endcase
    mul_lhs = SHARED_MUL_W'(a_sig);
    mul_rhs = SHARED_MUL_W'(b_sig);
    if (state == MUL_A_SCALE) begin mul_lhs=SHARED_MUL_W'(da.sig); mul_rhs=SHARED_MUL_W'(dsa.sig); end
    if (state == MUL_B_SCALE) begin mul_lhs=SHARED_MUL_W'(db.sig); mul_rhs=SHARED_MUL_W'(dsb.sig); end
    chunk = 0;
    if (word_index >= term_start && word_index-term_start < 5)
      chunk = 32'(term_window >> ((word_index-term_start) << 5));
    add_lhs = 0;
    add_rhs = 0;
    add_cin = 0;
    case (state)
      ACC_WRITE: begin
        add_lhs=ram_data; add_rhs=term_negative ? ~chunk : chunk; add_cin=carry;
      end
      ABS_WRITE: begin add_lhs=~ram_data; add_cin=carry; end
      DECODE_ABS: begin add_lhs=~abs_integer_bits; add_cin=1; end
      ROUND_LOW: begin add_lhs=round_sig[31:0]; add_cin=1; end
      ROUND_HIGH: begin add_lhs={10'b0,round_sig[53:32]}; add_cin=carry; end
      INT_NEGATE: begin add_lhs=~integer_low; add_cin=1; end
      default: ;
    endcase
    a_zero = da.is_zero || (cfg.block_scale_en && dsa.is_zero);
    b_zero = db.is_zero || (cfg.block_scale_en && dsb.is_zero);
    a_inf = da.is_inf || (cfg.block_scale_en && dsa.is_inf);
    b_inf = db.is_inf || (cfg.block_scale_en && dsb.is_inf);
    a_nan = da.is_nan || (cfg.block_scale_en &&
              (dsa.is_nan || (da.is_inf && dsa.is_zero) || (da.is_zero && dsa.is_inf)));
    b_nan = db.is_nan || (cfg.block_scale_en &&
              (dsb.is_nan || (db.is_inf && dsb.is_zero) || (db.is_zero && dsb.is_inf)));
    product_sign = da.sign ^ db.sign;
    increment_round = 0;
    case (cfg.rounding)
      ROUND_RNE: increment_round=guard_bit && (round_bit || sticky_bit || round_sig[0]);
      ROUND_RDN: increment_round=magnitude_negative && (guard_bit || round_bit || sticky_bit);
      ROUND_RUP: increment_round=!magnitude_negative && (guard_bit || round_bit || sticky_bit);
      default: ;
    endcase
    int_overflow = magnitude_negative ?
      (round_sig > 54'h00000080000000) : (round_sig > 54'h0000007fffffff);
    block_len = cfg.block_size == BLOCK16 ? 16 : 32;
    a_room = LANES;
    b_room = LANES;
    if (cfg.block_scale_en) begin
      a_room = block_len-((int'(cfg.a_block_offset)+int'(accepted_k)) & (block_len-1));
      b_room = block_len-((int'(cfg.b_block_offset)+int'(accepted_k)) & (block_len-1));
    end
    new_count = int'(accepted_k)+int'(op_count);
    lead=0;
    for (integer bit_index=0;bit_index<32;bit_index=bit_index+1)
      if (ram_data[bit_index]) lead=bit_index;
    exponent_high=acc_base+(word_index<<5)+lead;
    precision=int'(fmt_frac_bits(cfg.d_fmt))+1;
    min_quant=1-fmt_bias(cfg.d_fmt)-(precision-1);
    chosen_quant=exponent_high-(precision-1);
    if (chosen_quant < min_quant) chosen_quant=min_quant;
    if (integer_mode) chosen_quant=0;
  end

  task automatic fail(input malu_status_e why);
    rsp_status <= why;
    rsp_data <= 0;
    state <= RESPOND;
  endtask

  // Align only a 106-bit coefficient plus 31-bit offset, never all RAM bits.
  task automatic accumulate(input logic negative, input logic [105:0] sig,
                             input logic signed [15:0] exp,
                             input state_e after_term);
    integer shift, top;
    begin
      shift = int'($signed(exp))-acc_base;
      top = 0;
      for (integer q=0;q<106;q=q+1) if (sig[q]) top=q;
      if (shift < 0 || shift+top >= (active_words << 5)-1) begin
        fail(STATUS_RANGE);
      end else begin
        term_start <= shift >> 5;
        word_index <= shift >> 5;
        term_window <= {32'b0,sig} << (shift & 31);
        term_negative <= negative;
        carry <= negative;
        term_return <= after_term;
        state <= ACC_READ;
      end
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      rsp_data <= 0;
      rsp_tag <= 0;
      rsp_status <= STATUS_OK;
      cfg <= '0;
      c_bits <= 0;
      integer_mode <= 0;
      accepted_k <= 0;
      lane_index <= 0;
      beat_count <= 0;
      beat_last <= 0;
      active_words <= 0;
      acc_base <= 0;
      word_index <= 0;
      term_start <= 0;
      term_window <= 0;
      term_negative <= 0;
      term_return <= IDLE;
      ram_data <= 0;
      carry <= 0;
      da <= '0; db <= '0; dsa <= '0; dsb <= '0;
      a_sig <= 0; b_sig <= 0; a_exp <= 0; b_exp <= 0;
      a_cache <= '0; b_cache <= '0; sa_bits <= 0; sb_bits <= 0;
      saw_nan <= 0; saw_pos_inf <= 0; saw_neg_inf <= 0;
      zero_all_negative <= 1;
      zero_all_positive <= 1;
      magnitude_negative <= 0;
      cut_bit <= 0;
      round_sig <= 0;
      guard_bit <= 0; round_bit <= 0; sticky_bit <= 0;
      pack_nan <= 0; pack_inf <= 0; pack_zero <= 0; pack_sign <= 0;
      quant_exp <= 0;
      integer_low <= 0;
      abs_destination <= 0; abs_integer_bits <= 0; abs_return <= IDLE;
    end else begin
      case (state)
        IDLE: if (req_valid) begin
          cfg <= req_cfg;
          c_bits <= req_c;
          rsp_tag <= req_tag;
          rsp_data <= 0;
          rsp_status <= cfg_status(req_cfg,MAX_K,ENABLE_FP64);
          if (cfg_status(req_cfg,MAX_K,ENABLE_FP64) != STATUS_OK) state <= RESPOND;
          else begin
            integer_mode <= is_int(req_cfg.a_fmt);
            if (is_int(req_cfg.a_fmt)) begin active_words<=2; acc_base<=0; end
            else if (req_cfg.a_fmt == FMT_F64 || req_cfg.b_fmt == FMT_F64 ||
                     req_cfg.c_fmt == FMT_F64 || req_cfg.d_fmt == FMT_F64) begin
              active_words<=FULL_ACC_WORDS; acc_base<=FULL_ACC_BASE;
            end else begin active_words<=LOW_ACC_WORDS; acc_base<=LOW_ACC_BASE; end
            accepted_k <= 0;
            word_index <= 0;
            saw_nan <= 0; saw_pos_inf <= 0; saw_neg_inf <= 0;
            zero_all_negative <= 1;
            zero_all_positive <= 1;
            pack_nan <= 0; pack_inf <= 0; pack_zero <= 0; pack_sign <= 0;
            state <= CLEAR;
          end
        end
        CLEAR: begin
          acc_ram[word_index] <= 0;
          if (word_index == active_words-1) state <= DECODE_C;
          else word_index <= word_index+1;
        end
        DECODE_C: begin
          if (decoded.bad) fail(STATUS_BAD_ENCODING);
          else if (decode_abs) begin
            abs_integer_bits <= decoded.sig[31:0];
            abs_destination <= 0;
            abs_return <= WAIT_BEAT;
            state <= DECODE_ABS;
          end else begin
            if (decoded.is_nan) saw_nan <= 1;
            if (decoded.is_inf && decoded.sign) saw_neg_inf <= 1;
            if (decoded.is_inf && !decoded.sign) saw_pos_inf <= 1;
            if (!decoded.is_zero || !decoded.sign) zero_all_negative <= 0;
            if (!decoded.is_zero || decoded.sign) zero_all_positive <= 0;
            if (!decoded.is_nan && !decoded.is_inf && !decoded.is_zero)
              accumulate(decoded.sign,{53'b0,decoded.sig},
                16'($signed(decoded.exp)-$signed({12'b0,cfg.c_scale_shift})),WAIT_BEAT);
            else state <= WAIT_BEAT;
          end
        end
        DECODE_ABS: begin
          if (abs_destination == 0) begin
            zero_all_negative <= 0;
            zero_all_positive <= 0;
            accumulate(1'b1,{74'b0,add_result[31:0]},16'sd0,WAIT_BEAT);
          end else begin
            if (abs_destination == 1) da.sig <= {21'b0,add_result[31:0]};
            else db.sig <= {21'b0,add_result[31:0]};
            state <= abs_return;
          end
        end
        WAIT_BEAT: if (op_valid) begin
          if (op_count == 0 || int'(op_count) > LANES || new_count > int'(cfg.k) ||
              op_last != (new_count == int'(cfg.k)) ||
              (cfg.block_scale_en && (int'(op_count)>a_room || int'(op_count)>b_room))) begin
            fail(STATUS_LENGTH);
          end else if (cfg.block_scale_en && accepted_k != 0 &&
              ((a_room != block_len && op_scale_a != sa_bits) ||
               (b_room != block_len && op_scale_b != sb_bits))) begin
            // Payload is repeated per beat; within each logical scale block it
            // must agree with the cached payload from the preceding beat.
            fail(STATUS_BAD_ENCODING);
          end else begin
            a_cache <= op_a; b_cache <= op_b;
            sa_bits <= op_scale_a; sb_bits <= op_scale_b;
            beat_count <= int'(op_count);
            beat_last <= op_last;
            accepted_k <= 17'(new_count);
            lane_index <= 0;
            state <= DECODE_A;
          end
        end
        DECODE_A: begin
          da <= decoded;
          if (decoded.bad) fail(STATUS_BAD_ENCODING);
          else if (decode_abs) begin
            abs_integer_bits<=decoded.sig[31:0]; abs_destination<=1;
            abs_return<=DECODE_B; state<=DECODE_ABS;
          end else state <= DECODE_B;
        end
        DECODE_B: begin
          db <= decoded;
          if (decoded.bad) fail(STATUS_BAD_ENCODING);
          else if (decode_abs) begin
            abs_integer_bits<=decoded.sig[31:0]; abs_destination<=2;
            abs_return<=cfg.block_scale_en ? DECODE_SA : PREPARE; state<=DECODE_ABS;
          end else state <= cfg.block_scale_en ? DECODE_SA : PREPARE;
        end
        DECODE_SA: begin
          dsa<=decoded;
          if (decoded.bad) fail(STATUS_BAD_ENCODING);
          else state<=DECODE_SB;
        end
        DECODE_SB: begin
          dsb<=decoded;
          if (decoded.bad) fail(STATUS_BAD_ENCODING);
          else state<=PREPARE;
        end
        PREPARE: begin
          if (cfg.a_fmt == FMT_B1) begin
            zero_all_negative <= 0;
            zero_all_positive <= 0;
            if (cfg.binary_xor ? (da.sig[0]^db.sig[0]) : (da.sig[0]&db.sig[0]))
              accumulate(0,106'd1,16'sd0,NEXT_ITEM);
            else state<=NEXT_ITEM;
          end else if (a_nan || b_nan || (a_zero && b_inf) || (b_zero && a_inf)) begin
            saw_nan<=1; state<=NEXT_ITEM;
          end else if (a_inf || b_inf) begin
            if (product_sign) saw_neg_inf<=1;
            else saw_pos_inf<=1;
            state<=NEXT_ITEM;
          end else if (a_zero || b_zero) begin
            if (!product_sign) zero_all_negative<=0;
            if (product_sign) zero_all_positive<=0;
            state<=NEXT_ITEM;
          end else begin
            zero_all_negative<=0;
            zero_all_positive<=0;
            a_sig<=da.sig; b_sig<=db.sig; a_exp<=da.exp; b_exp<=db.exp;
            state<=cfg.block_scale_en ? MUL_A_SCALE : MUL_AB;
          end
        end
        MUL_A_SCALE: begin
          if (|mul_product[105:53]) fail(STATUS_RANGE);
          else begin a_sig<=mul_product[52:0]; a_exp<=16'($signed(da.exp)+$signed(dsa.exp)); state<=MUL_B_SCALE; end
        end
        MUL_B_SCALE: begin
          if (|mul_product[105:53]) fail(STATUS_RANGE);
          else begin b_sig<=mul_product[52:0]; b_exp<=16'($signed(db.exp)+$signed(dsb.exp)); state<=MUL_AB; end
        end
        MUL_AB: accumulate(product_sign,mul_product,16'($signed(a_exp)+$signed(b_exp)),NEXT_ITEM);
        ACC_READ: begin ram_data<=acc_ram[word_index]; state<=ACC_WRITE; end
        ACC_WRITE: begin
          acc_ram[word_index]<=add_result[31:0];
          carry<=add_result[32];
          if (word_index == active_words-1) state<=term_return;
          else begin word_index<=word_index+1; state<=ACC_READ; end
        end
        NEXT_ITEM: begin
          if (lane_index+1 < beat_count) begin lane_index<=lane_index+1; state<=DECODE_A; end
          else if (!beat_last) state<=WAIT_BEAT;
          else if (saw_nan || (saw_pos_inf && saw_neg_inf)) begin
            pack_nan<=1; state<=PACK;
          end else if (saw_pos_inf || saw_neg_inf) begin
            pack_inf<=1; pack_sign<=saw_neg_inf; state<=PACK;
          end else begin word_index<=active_words-1; state<=SIGN_READ; end
        end
        SIGN_READ: begin ram_data<=acc_ram[word_index]; state<=SIGN_TEST; end
        SIGN_TEST: begin
          magnitude_negative<=ram_data[31];
          if (ram_data[31]) begin word_index<=0; carry<=1; state<=ABS_READ; end
          else begin word_index<=active_words-1; state<=MSB_READ; end
        end
        ABS_READ: begin ram_data<=acc_ram[word_index]; state<=ABS_WRITE; end
        ABS_WRITE: begin
          acc_ram[word_index]<=add_result[31:0]; carry<=add_result[32];
          if (word_index == active_words-1) begin word_index<=active_words-1; state<=MSB_READ; end
          else begin word_index<=word_index+1; state<=ABS_READ; end
        end
        MSB_READ: begin ram_data<=acc_ram[word_index]; state<=MSB_TEST; end
        MSB_TEST: begin
          if (ram_data != 0) begin
            if (integer_mode) cut_bit<=0;
            else cut_bit<=chosen_quant-acc_base;
            quant_exp<=16'(chosen_quant);
            round_sig<=0; guard_bit<=0; round_bit<=0; sticky_bit<=0;
            pack_sign<=magnitude_negative;
            word_index<=0; state<=GATHER_READ;
          end else if (word_index != 0) begin word_index<=word_index-1; state<=MSB_READ; end
          else if (integer_mode) begin rsp_data<=0; state<=RESPOND; end
          else begin
            pack_zero<=1;
            pack_sign<=zero_all_negative || (!zero_all_positive && cfg.rounding==ROUND_RDN);
            state<=PACK;
          end
        end
        GATHER_READ: begin ram_data<=acc_ram[word_index]; state<=GATHER_TEST; end
        GATHER_TEST: begin
          for (integer bit_index=0;bit_index<32;bit_index=bit_index+1) begin
            if ((word_index<<5)+bit_index >= cut_bit && (word_index<<5)+bit_index-cut_bit < 54)
              round_sig[(word_index<<5)+bit_index-cut_bit]<=ram_data[bit_index];
            if ((word_index<<5)+bit_index == cut_bit-1) guard_bit<=ram_data[bit_index];
            if ((word_index<<5)+bit_index == cut_bit-2) round_bit<=ram_data[bit_index];
          end
          // Reduction OR is accumulated once per word; do not overwrite a
          // nonblocking sticky update with later zero bits in the same word.
          for (integer bit_index=0;bit_index<32;bit_index=bit_index+1)
            if ((word_index<<5)+bit_index < cut_bit-2 && ram_data[bit_index]) sticky_bit<=1;
          if (word_index == active_words-1) state<=integer_mode ? INT_FINISH : ROUND_DECIDE;
          else begin word_index<=word_index+1; state<=GATHER_READ; end
        end
        ROUND_DECIDE: if (increment_round) state<=ROUND_LOW; else state<=PACK;
        ROUND_LOW: begin round_sig[31:0]<=add_result[31:0]; carry<=add_result[32]; state<=ROUND_HIGH; end
        ROUND_HIGH: begin round_sig[53:32]<=add_result[21:0]; state<=PACK; end
        INT_FINISH: begin
          if (cfg.int_sat && int_overflow) begin
            rsp_data<={32'b0,magnitude_negative ? 32'h80000000 : 32'h7fffffff}; state<=RESPOND;
          end else if (magnitude_negative) begin integer_low<=round_sig[31:0]; state<=INT_NEGATE; end
          else begin rsp_data<={32'b0,round_sig[31:0]}; state<=RESPOND; end
        end
        INT_NEGATE: begin rsp_data<={32'b0,add_result[31:0]}; state<=RESPOND; end
        PACK: begin rsp_data<=packed_data; state<=RESPOND; end
        RESPOND: if (rsp_ready) state<=IDLE;
        default: state<=IDLE;
      endcase
    end
  end
endmodule

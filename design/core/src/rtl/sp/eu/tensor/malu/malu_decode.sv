// PROJECT_EXACT element decoder. Signed integer magnitude conversion is deferred
// to the core's shared word adder when needs_abs is asserted.
module malu_decode (
  input  logic [63:0] raw,
  input  malu_pkg::malu_fmt_e fmt,
  input  logic ti16_decoded,
  output malu_pkg::malu_dec_t dec,
  output logic needs_abs
);
  import malu_pkg::*;
  integer w, eb, fb, bias, ex;
  logic [63:0] frac_mask, frac, ex_mask, bits_mask;
  logic [31:0] int_bits;
  logic signed_integer;
  always_comb begin
    dec = '0;
    needs_abs = 1'b0;
    w = int'(fmt_width(fmt));
    eb = int'(fmt_exp_bits(fmt));
    fb = int'(fmt_frac_bits(fmt));
    bias = fmt_bias(fmt);
    ex = 0;
    frac_mask = 0;
    frac = 0;
    ex_mask = 0;
    bits_mask = 0;
    int_bits = 0;
    signed_integer = 0;
    if (is_int(fmt) || fmt == FMT_S32) begin
      bits_mask = (64'h1 << w) - 1;
      int_bits = 32'(raw & bits_mask);
      signed_integer = fmt inside {FMT_S8,FMT_S4,FMT_TI16,FMT_S32};
      dec.sign = signed_integer && raw[w-1];
      if (dec.sign && w < 32) int_bits = int_bits | (32'hffff_ffff << w);
      dec.sig = {21'b0,int_bits};
      dec.exp = 0;
      dec.is_zero = (raw & bits_mask) == 0;
      needs_abs = dec.sign;
      if (fmt == FMT_TI16 &&
          (!ti16_decoded || $signed(raw[15:0]) < -16'sd2047 ||
                           $signed(raw[15:0]) > 16'sd2047)) dec.bad = 1;
    end else if (fmt == FMT_UE8M0) begin
      dec.is_nan = raw[7:0] == 8'hff;
      dec.sig = 53'd1;
      dec.exp = 16'(int'(raw[7:0])-127);
    end else if (is_fp(fmt) || fmt inside {FMT_UE4M3,FMT_UE5M3}) begin
      ex_mask = (64'h1 << eb)-1;
      frac_mask = (64'h1 << fb)-1;
      dec.sign = is_fp(fmt) ? raw[w-1] : 1'b0;
      if (fmt == FMT_TF32) begin
        ex = int'((raw >> 23) & ex_mask);
        frac = (raw >> 13) & frac_mask;
        if (raw[12:0] != 0) dec.bad = 1;
      end else begin
        ex = int'((raw >> fb) & ex_mask);
        frac = raw & frac_mask;
      end
      if (fmt == FMT_UE4M3 && raw[7]) dec.bad = 1;
      if (fmt_has_inf(fmt) && ex == int'(ex_mask)) begin
        dec.is_inf = frac == 0;
        dec.is_nan = frac != 0;
      end else if (fmt inside {FMT_E4M3,FMT_UE4M3,FMT_UE5M3} &&
                   ex == int'(ex_mask) && frac == frac_mask) begin
        dec.is_nan = 1;
      end else begin
        dec.sig = 53'(frac);
        dec.is_zero = ex == 0 && frac == 0;
        if (ex != 0) dec.sig[fb] = 1;
        dec.exp = 16'((ex == 0 ? 1 : ex)-bias-fb);
      end
    end else begin
      dec.bad = 1;
    end
  end
endmodule

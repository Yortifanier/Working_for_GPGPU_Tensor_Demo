// Pure IEEE result encoding. The shared core adder has already rounded the
// magnitude integer: value = rounded_sig * 2**quant_exp. No rounding adder here.
module malu_round_pack (
  input  malu_pkg::malu_fmt_e fmt,
  input  malu_pkg::malu_round_e rounding,
  input  logic sign,
  input  logic is_nan, is_inf, is_zero,
  input  logic [53:0] rounded_sig,
  input  logic signed [15:0] quant_exp,
  output logic [63:0] data
);
  import malu_pkg::*;
  integer w, eb, fb, ef, max_ef, j;
  logic [53:0] significand;
  logic overflow_to_inf;
  always_comb begin
    data = 0;
    w = int'(fmt_width(fmt));
    eb = int'(fmt_exp_bits(fmt));
    fb = int'(fmt_frac_bits(fmt));
    max_ef = (1 << eb)-1;
    ef = 0;
    significand = rounded_sig;
    overflow_to_inf = rounding == ROUND_RNE ||
       (rounding == ROUND_RDN && sign) ||
       (rounding == ROUND_RUP && !sign);
    if (is_fp_result(fmt)) begin
      data[w-1] = sign;
      if (is_nan) begin
        data = 0;
        for (j=0;j<11;j=j+1) if (j<eb) data[fb+j] = 1;
        data[fb-1] = 1; // Positive canonical quiet NaN.
      end else if (is_inf) begin
        for (j=0;j<11;j=j+1) if (j<eb) data[fb+j] = 1;
      end else if (!is_zero && rounded_sig != 0) begin
        if (significand[fb+1]) begin
          significand = significand >> 1;
          ef = int'($signed(quant_exp))+fb+fmt_bias(fmt)+1;
        end else if (significand[fb]) begin
          ef = int'($signed(quant_exp))+fb+fmt_bias(fmt);
        end
        if (ef >= max_ef) begin
          for (j=0;j<11;j=j+1)
            if (j<eb) data[fb+j] = overflow_to_inf ? 1'b1 : (j != 0);
          if (!overflow_to_inf)
            for (j=0;j<52;j=j+1) if (j<fb) data[j] = 1;
        end else begin
          for (j=0;j<11;j=j+1) if (j<eb) data[fb+j] = 1'((ef >> j) & 1);
          for (j=0;j<52;j=j+1) if (j<fb) data[j] = significand[j];
        end
      end
    end
  end
endmodule

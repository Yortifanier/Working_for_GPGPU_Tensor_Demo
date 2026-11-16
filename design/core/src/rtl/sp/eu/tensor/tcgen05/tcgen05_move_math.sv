// Shared comparison/selection circuit for TMEM load transformations. Floating
// point values are ordered from their IEEE bit encodings; no simulator real
// arithmetic is used. Compression ties select the lower source index, one of
// the implementation-specific choices permitted by PTX spcompress.
module tcgen05_move_math (
  input logic [31:0] red_lhs, red_rhs,
  input tcgen05_pkg::tc_red_type_e red_type,
  input logic select_max, use_abs, propagate_nan,
  output logic [31:0] red_result,
  input logic [3:0][31:0] sp_values,
  output logic [1:0][31:0] sp_data,
  output logic [3:0] sp_indices
);
  import tcgen05_pkg::*;
  function automatic logic is_nan(input logic [31:0] x);
    return &x[30:23] && |x[22:0];
  endfunction
  function automatic logic [31:0] fp_key(input logic [31:0] x);
    return x[31] ? ~x : (x ^ 32'h80000000);
  endfunction
  function automatic logic prefer(input logic [31:0] x, y,
                                  input int x_index, y_index);
    logic [31:0] a, b;
    if (is_nan(x) != is_nan(y)) return is_nan(x);
    if (is_nan(x)) return x_index < y_index;
    a = use_abs ? {1'b0,x[30:0]} : x;
    b = use_abs ? {1'b0,y[30:0]} : y;
    if (a == b) return x_index < y_index;
    return select_max ? fp_key(a)>fp_key(b) : fp_key(a)<fp_key(b);
  endfunction
  logic [31:0] a, b;
  int first, second, low_index, high_index;
  always_comb begin
    a = red_lhs; b = red_rhs;
    if (red_type == TC_RED_F32) begin
      if (use_abs) begin a[31]=0; b[31]=0; end
      if (is_nan(a) && is_nan(b)) red_result = 32'h7fc00000;
      else if (propagate_nan && (is_nan(a) || is_nan(b))) red_result=32'h7fc00000;
      else if (is_nan(a)) red_result=b;
      else if (is_nan(b)) red_result=a;
      else if (select_max) red_result=fp_key(a)>fp_key(b) ? a : b;
      else red_result=fp_key(a)<fp_key(b) ? a : b;
    end else if (red_type == TC_RED_S32) begin
      if (select_max) red_result=$signed(a)>$signed(b) ? a : b;
      else red_result=$signed(a)<$signed(b) ? a : b;
    end else begin
      if (select_max) red_result=a>b ? a : b;
      else red_result=a<b ? a : b;
    end
    first=0;
    for (int i=1; i<4; i++)
      if (prefer(sp_values[i],sp_values[first],i,first)) first=i;
    second=first==0 ? 1 : 0;
    for (int i=0; i<4; i++)
      if (i!=first && prefer(sp_values[i],sp_values[second],i,second)) second=i;
    // The compressed stream preserves source order; metadata is two b2 indices.
    low_index=first<second ? first : second;
    high_index=first<second ? second : first;
    sp_data[0]=sp_values[low_index];
    sp_data[1]=sp_values[high_index];
    sp_indices={2'(high_index),2'(low_index)};
  end
endmodule

module tb_tcgen05_move_math;
  import tcgen05_pkg::*;
  logic [31:0] red_lhs,red_rhs,red_result;
  tc_red_type_e red_type;
  logic select_max,use_abs,propagate_nan;
  logic [3:0][31:0] sp_values;
  logic [1:0][31:0] sp_data;
  logic [3:0] sp_indices;
  tcgen05_move_math dut(.*);
  string filename;
  integer stream,read_fields,cases;
  logic [31:0] type_bits,max_bits,abs_bits,nan_bits,expected_red,expected0,expected1,expected_indices;
  initial begin
    if (!$value$plusargs("VECTORS=%s",filename)) $fatal(1,"VECTORS required");
    stream=$fopen(filename,"r");
    if (stream==0) $fatal(1,"Cannot open vectors");
    cases=0;
    while (!$feof(stream)) begin
      read_fields=$fscanf(stream,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
        red_lhs,red_rhs,type_bits,max_bits,abs_bits,nan_bits,
        sp_values[0],sp_values[1],sp_values[2],sp_values[3],expected_red,expected0,expected1,expected_indices);
      if (read_fields!=14) $fatal(1,"Bad vector row %0d fields%0d",cases,read_fields);
      red_type=tc_red_type_e'(type_bits[1:0]);select_max=max_bits[0];use_abs=abs_bits[0];propagate_nan=nan_bits[0];
      #1;
      if (red_result!==expected_red || sp_data[0]!==expected0 || sp_data[1]!==expected1 || sp_indices!==expected_indices[3:0])
        $fatal(1,"MOVE_MATH mismatch vector%0d red=%h/%h compressed=%h,%h/%h,%h meta%h/%h",cases,
          red_result,expected_red,sp_data[0],sp_data[1],expected0,expected1,sp_indices,expected_indices);
      cases=cases+1;
    end
    $fclose(stream);
    if (cases==0) $fatal(1,"No tests");
    $display("TCGEN05_MOVE_MATH_PASS vectors=%0d",cases);
    $finish;
  end
endmodule

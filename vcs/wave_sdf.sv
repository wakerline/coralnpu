`ifdef SVT_FSDB_ENABLE

`define STRINGIFY(x) `"x`"

module ara_tb_fsdb_dump;

initial begin : dump_fsdb
`ifdef FSDB_PATH
  string fsdb_path = `STRINGIFY(`FSDB_PATH);
`else
  string fsdb_path = "ara_tb.fsdb";
`endif
  $display("[VCS - FSDB] Dumping to %s", fsdb_path);
  $fsdbDumpfile(fsdb_path);
  $fsdbDumpvars(0, ara_tb);
end

endmodule

bind ara_tb ara_tb_fsdb_dump ara_tb_fsdb_dump_i();

`endif

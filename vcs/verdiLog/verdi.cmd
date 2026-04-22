verdiSetActWin -dock widgetDock_<Message>
simSetSimulator "-vcssv" -exec "./simv" -args \
           "-sv_lib /home/wangyy/003_research/ara_clean/hardware/build/work-dpi/ara_dpi +lint=TFIPC-L +vcs+loopreport +PRELOAD=/home/wangyy/003_research/ara_clean/apps/bin/rv64uv-ara-vadd"
debImport "-dbdir" "./simv.daidir"
debLoadSimResult /home/wangyy/003_research/ara_clean/hardware/vcs/ara_tb.fsdb
wvCreateWindow
verdiWindowResize -win $_Verdi_1 "615" "273" "900" "700"
verdiSetActWin -dock widgetDock_MTB_SOURCE_TAB_1
verdiSetActWin -dock widgetDock_<Inst._Tree>
srcHBSelect "ara_tb.dut.i_ara_soc.i_system.i_ara.i_dispatcher" -win $_nTrace1
srcSetScope "ara_tb.dut.i_ara_soc.i_system.i_ara.i_dispatcher" -delim "." -win \
           $_nTrace1
srcHBSelect "ara_tb.dut.i_ara_soc.i_system.i_ara.i_dispatcher" -win $_nTrace1
srcDeselectAll -win $_nTrace1
srcSelect -win $_nTrace1 -signal "FPUSupportHalfSingleDouble" -line 22 -pos 1
verdiSetActWin -dock widgetDock_MTB_SOURCE_TAB_1
srcDeselectAll -win $_nTrace1
srcSelect -signal "clk_i" -line 34 -pos 1 -win $_nTrace1
debExit

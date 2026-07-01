vlib work
vmap work work

vlog +acc +sv Neuromorphic_X2_wb_beh.v tb_Neuromorphic_X2_wb_beh.v

vsim work.tb_Neuromorphic_X2_wb_beh

add wave -position insertpoint sim:/tb_Neuromorphic_X2_wb_beh/*

run -all
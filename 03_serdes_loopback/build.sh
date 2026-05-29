#!/bin/bash
set -e
TOP=serdes_top
yosys -p "read_verilog ${TOP}.v; synth_gatemate -top ${TOP} -luttree -nomx8; write_json ${TOP}.json"
nextpnr-himbaechel --device=CCGM1A1 --json ${TOP}.json -o ccf=${TOP}.ccf -o out=${TOP}.txt --router router2 --timing-allow-fail
gmpack ${TOP}.txt ${TOP}.bit
openFPGALoader -c gatemate_evb_jtag -r ${TOP}.bit

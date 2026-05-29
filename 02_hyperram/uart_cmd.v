module uart_cmd (
    input  wire clk,
    input  wire rx,
    output reg  tx,
    output reg  led,
    output wire       hram_clk_p,
    output wire       hram_clk_n,
    output wire       hram_cs_n,
    output wire       hram_rst_n,
    inout  wire [7:0] hram_dq,
    inout  wire       hram_rwds
);

wire clk_fast;
wire clk_fast_90;
CC_PLL #(.REF_CLK("10.0"),.OUT_CLK("50.0"),.PERF_MD("ECONOMY"),
         .LOW_JITTER(1),.CI_FILTER_CONST(2),.CP_FILTER_CONST(4),
         .LOCK_REQ(1),.CLK270_DOUB(0),.CLK180_DOUB(0)) pll_inst (
    .CLK_REF(clk),.CLK_FEEDBACK(1'b0),.USR_CLK_REF(1'b0),
    .USR_LOCKED_STDY_RST(1'b0),.USR_PLL_LOCKED_STDY(),.USR_PLL_LOCKED(),
    .CLK270(),.CLK180(),.CLK0(clk_fast),.CLK90  (clk_fast_90),.CLK_REF_OUT());

wire usr_rstn;
CC_USR_RSTN rstn_inst (.USR_RSTN(usr_rstn));
reg rst_sync0=0, rst_sync1=0;
always @(posedge clk_fast) begin rst_sync0<=usr_rstn; rst_sync1<=rst_sync0; end
wire rst_n = rst_sync1;

parameter CLK_FREQ = 50_000_000;
parameter BAUD_RATE  = 57600;
localparam BIT_PERIOD  = CLK_FREQ / BAUD_RATE;
localparam HALF_PERIOD = BIT_PERIOD / 2;
localparam CR=8'h0D, LF=8'h0A, NUL=8'h00, SP=8'h20;

reg rx_s0=1, rx_s1=1, rx_s2=1;
wire rx_sync = rx_s2;
always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin rx_s0<=1; rx_s1<=1; rx_s2<=1; end
    else begin rx_s0<=rx; rx_s1<=rx_s0; rx_s2<=rx_s1; end
end

localparam RX_IDLE=2'd0,RX_START=2'd1,RX_DATA=2'd2,RX_STOP=2'd3;
reg [1:0] rx_state=RX_IDLE;
reg [9:0] rx_cnt=0;
reg [2:0] rx_bit_idx=0;
reg [7:0] rx_shift=0;
reg       rx_valid=0;
reg [7:0] rx_byte=0;
always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin rx_state<=RX_IDLE; rx_valid<=0; end
    else begin
        rx_valid<=0;
        case (rx_state)
            RX_IDLE:  if (rx_sync==0) begin rx_state<=RX_START; rx_cnt<=HALF_PERIOD-1; end
            RX_START: if (rx_cnt==0) begin
                          if (rx_sync==0) begin rx_state<=RX_DATA; rx_cnt<=BIT_PERIOD-1; rx_bit_idx<=0; end
                          else rx_state<=RX_IDLE;
                      end else rx_cnt<=rx_cnt-1;
            RX_DATA:  if (rx_cnt==0) begin
                          rx_shift<={rx_sync,rx_shift[7:1]}; rx_cnt<=BIT_PERIOD-1;
                          if (rx_bit_idx==7) rx_state<=RX_STOP; else rx_bit_idx<=rx_bit_idx+1;
                      end else rx_cnt<=rx_cnt-1;
            RX_STOP:  if (rx_cnt==0) begin
                          rx_state<=RX_IDLE;
                          if (rx_sync==1) begin rx_byte<=rx_shift; rx_valid<=1; end
                      end else rx_cnt<=rx_cnt-1;
        endcase
    end
end

reg [7:0] cmd_buf [0:15];
reg [3:0] cmd_len=0;
reg       cmd_ready=0, cmd_done=0;

function [7:0] to_upper;
    input [7:0] ch;
    begin if (ch>=8'h61&&ch<=8'h7A) to_upper=ch&8'hDF; else to_upper=ch; end
endfunction
function [3:0] hex_to_val;
    input [7:0] ch;
    begin if (ch>=8'h41) hex_to_val=ch-8'h37; else hex_to_val=ch-8'h30; end
endfunction
function [7:0] nibble_to_hex;
    input [3:0] n;
    begin if (n<10) nibble_to_hex=n+8'h30; else nibble_to_hex=n+8'h37; end
endfunction

reg [7:0] echo_byte=0;
reg       echo_req=0;
always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin cmd_len<=0; cmd_ready<=0; echo_req<=0; end
    else begin
        cmd_ready<=0; echo_req<=0;
        if (rx_valid) begin
            if (rx_byte==CR||rx_byte==LF) begin
                if (cmd_len>0) begin echo_byte<=LF; echo_req<=1; cmd_ready<=1; end
            end else if (cmd_len<15) begin
                echo_byte<=rx_byte; echo_req<=1;
                cmd_buf[cmd_len]<=to_upper(rx_byte); cmd_len<=cmd_len+1;
            end
        end
        if (cmd_done) cmd_len<=0;
    end
end

reg [7:0] rom [0:350];
initial begin
    rom[0]="L";rom[1]="E";rom[2]="D";rom[3]=" ";rom[4]="O";rom[5]="N";rom[6]="\r";rom[7]="\n";rom[8]=NUL;
    rom[20]="L";rom[21]="E";rom[22]="D";rom[23]=" ";rom[24]="O";rom[25]="F";rom[26]="F";rom[27]="\r";rom[28]="\n";rom[29]=NUL;
    rom[40]="G";rom[41]="a";rom[42]="t";rom[43]="e";rom[44]="M";rom[45]="a";rom[46]="t";rom[47]="e";rom[48]=" ";rom[49]="O";rom[50]="K";rom[51]="\r";rom[52]="\n";rom[53]=NUL;
    rom[60]="C";rom[61]="L";rom[62]="K";rom[63]=":";rom[64]=" ";rom[65]="5";rom[66]="0";rom[67]="M";rom[68]="H";rom[69]="z";rom[70]=" ";rom[71]="-";rom[72]=" ";rom[73]="P";rom[74]="L";rom[75]="L";rom[76]=" ";rom[77]="L";rom[78]="O";rom[79]="C";rom[80]="K";rom[81]="E";rom[82]="D";rom[83]="\r";rom[84]="\n";rom[85]=NUL;
    rom[90]="B";rom[91]="l";rom[92]="i";rom[93]="n";rom[94]="k";rom[95]="i";rom[96]="n";rom[97]="g";rom[98]=":";rom[99]=" ";rom[100]="S";rom[101]="L";rom[102]="O";rom[103]="W";rom[104]="\r";rom[105]="\n";rom[106]=NUL;
    rom[110]="B";rom[111]="l";rom[112]="i";rom[113]="n";rom[114]="k";rom[115]="i";rom[116]="n";rom[117]="g";rom[118]=":";rom[119]=" ";rom[120]="F";rom[121]="A";rom[122]="S";rom[123]="T";rom[124]="\r";rom[125]="\n";rom[126]=NUL;
    rom[130]="B";rom[131]="l";rom[132]="i";rom[133]="n";rom[134]="k";rom[135]="i";rom[136]="n";rom[137]="g";rom[138]=":";rom[139]=" ";rom[140]="O";rom[141]="F";rom[142]="F";rom[143]="\r";rom[144]="\n";rom[145]=NUL;
    rom[150]="C";rom[151]="o";rom[152]="u";rom[153]="n";rom[154]="t";rom[155]="e";rom[156]="r";rom[157]=":";rom[158]=" ";rom[159]=NUL;
    rom[160]="\r";rom[161]="\n";rom[162]=NUL;
    rom[170]="C";rom[171]="o";rom[172]="m";rom[173]="m";rom[174]="a";rom[175]="n";rom[176]="d";rom[177]="s";rom[178]=":";rom[179]="\r";rom[180]="\n";
    rom[181]=" ";rom[182]="L";rom[183]="E";rom[184]="D";rom[185]=" ";rom[186]="O";rom[187]="N";rom[188]="\r";rom[189]="\n";
    rom[190]=" ";rom[191]="L";rom[192]="E";rom[193]="D";rom[194]=" ";rom[195]="O";rom[196]="F";rom[197]="F";rom[198]="\r";rom[199]="\n";
    rom[200]=" ";rom[201]="B";rom[202]="L";rom[203]="I";rom[204]="N";rom[205]="K";rom[206]=" ";rom[207]="S";rom[208]="L";rom[209]="O";rom[210]="W";rom[211]="\r";rom[212]="\n";
    rom[213]=" ";rom[214]="B";rom[215]="L";rom[216]="I";rom[217]="N";rom[218]="K";rom[219]=" ";rom[220]="F";rom[221]="A";rom[222]="S";rom[223]="T";rom[224]="\r";rom[225]="\n";
    rom[226]=" ";rom[227]="B";rom[228]="L";rom[229]="I";rom[230]="N";rom[231]="K";rom[232]=" ";rom[233]="O";rom[234]="F";rom[235]="F";rom[236]="\r";rom[237]="\n";
    rom[238]=" ";rom[239]="C";rom[240]="O";rom[241]="U";rom[242]="N";rom[243]="T";rom[244]="\r";rom[245]="\n";
    rom[246]=" ";rom[247]="S";rom[248]="T";rom[249]="A";rom[250]="T";rom[251]="U";rom[252]="S";rom[253]="\r";rom[254]="\n";
    rom[255]=" ";rom[256]="W";rom[257]="R";rom[258]="I";rom[259]="T";rom[260]="E";rom[261]=" ";rom[262]="X";rom[263]="X";rom[264]=" ";rom[265]="Y";rom[266]="Y";rom[267]="\r";rom[268]="\n";
    rom[269]=" ";rom[270]="R";rom[271]="E";rom[272]="A";rom[273]="D";rom[274]=" ";rom[275]="X";rom[276]="X";rom[277]="\r";rom[278]="\n";
    rom[279]=" ";rom[280]="H";rom[281]="E";rom[282]="L";rom[283]="P";rom[284]="\r";rom[285]="\n";rom[286]=NUL;
    rom[290]="U";rom[291]="n";rom[292]="k";rom[293]="n";rom[294]="o";rom[295]="w";rom[296]="n";rom[297]=" ";rom[298]="c";rom[299]="o";rom[300]="m";rom[301]="m";rom[302]="a";rom[303]="n";rom[304]="d";rom[305]="\r";rom[306]="\n";rom[307]=NUL;
    rom[310]="W";rom[311]="r";rom[312]="i";rom[313]="t";rom[314]="t";rom[315]="e";rom[316]="n";rom[317]=":";rom[318]=" ";rom[319]="0";rom[320]="x";rom[321]=NUL;
    rom[325]="R";rom[326]="e";rom[327]="a";rom[328]="d";rom[329]=":";rom[330]=" ";rom[331]="0";rom[332]="x";rom[333]=NUL;
    rom[340]="H";rom[341]="R";rom[342]="A";rom[343]="M";rom[344]=" ";rom[345]="E";rom[346]="R";rom[347]="R";rom[348]="\r";rom[349]="\n";rom[350]=NUL;
end

wire is_led_on  = (cmd_len==6)&&cmd_buf[0]=="L"&&cmd_buf[1]=="E"&&cmd_buf[2]=="D"&&cmd_buf[3]==" "&&cmd_buf[4]=="O"&&cmd_buf[5]=="N";
wire is_led_off = (cmd_len==7)&&cmd_buf[0]=="L"&&cmd_buf[1]=="E"&&cmd_buf[2]=="D"&&cmd_buf[3]==" "&&cmd_buf[4]=="O"&&cmd_buf[5]=="F"&&cmd_buf[6]=="F";
wire is_status  = (cmd_len==6)&&cmd_buf[0]=="S"&&cmd_buf[1]=="T"&&cmd_buf[2]=="A"&&cmd_buf[3]=="T"&&cmd_buf[4]=="U"&&cmd_buf[5]=="S";
wire is_clkinfo = (cmd_len==7)&&cmd_buf[0]=="C"&&cmd_buf[1]=="L"&&cmd_buf[2]=="K"&&cmd_buf[3]=="I"&&cmd_buf[4]=="N"&&cmd_buf[5]=="F"&&cmd_buf[6]=="O";
wire is_help    = (cmd_len==4)&&cmd_buf[0]=="H"&&cmd_buf[1]=="E"&&cmd_buf[2]=="L"&&cmd_buf[3]=="P";
wire is_blink_slow=(cmd_len==10)&&cmd_buf[0]=="B"&&cmd_buf[1]=="L"&&cmd_buf[2]=="I"&&cmd_buf[3]=="N"&&cmd_buf[4]=="K"&&cmd_buf[5]==" "&&cmd_buf[6]=="S"&&cmd_buf[7]=="L"&&cmd_buf[8]=="O"&&cmd_buf[9]=="W";
wire is_blink_fast=(cmd_len==10)&&cmd_buf[0]=="B"&&cmd_buf[1]=="L"&&cmd_buf[2]=="I"&&cmd_buf[3]=="N"&&cmd_buf[4]=="K"&&cmd_buf[5]==" "&&cmd_buf[6]=="F"&&cmd_buf[7]=="A"&&cmd_buf[8]=="S"&&cmd_buf[9]=="T";
wire is_blink_off =(cmd_len==9) &&cmd_buf[0]=="B"&&cmd_buf[1]=="L"&&cmd_buf[2]=="I"&&cmd_buf[3]=="N"&&cmd_buf[4]=="K"&&cmd_buf[5]==" "&&cmd_buf[6]=="O"&&cmd_buf[7]=="F"&&cmd_buf[8]=="F";
wire is_count     =(cmd_len==5) &&cmd_buf[0]=="C"&&cmd_buf[1]=="O"&&cmd_buf[2]=="U"&&cmd_buf[3]=="N"&&cmd_buf[4]=="T";
wire is_write     =(cmd_len==11)&&cmd_buf[0]=="W"&&cmd_buf[1]=="R"&&cmd_buf[2]=="I"&&cmd_buf[3]=="T"&&cmd_buf[4]=="E"&&cmd_buf[5]==" "&&cmd_buf[8]==" ";
wire is_read      =(cmd_len==7) &&cmd_buf[0]=="R"&&cmd_buf[1]=="E"&&cmd_buf[2]=="A"&&cmd_buf[3]=="D"&&cmd_buf[4]==" ";

reg led_direct=1;
reg [1:0]  blink_mode=0;
reg [25:0] blink_cnt=0;
localparam BLINK_SLOW_TOP = 25_000_000;
localparam BLINK_FAST_TOP =  2_500_000;
always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin blink_cnt<=0; led<=1; end
    else case (blink_mode)
        0: begin led<=led_direct; blink_cnt<=0; end
        1: begin if (blink_cnt>=BLINK_SLOW_TOP) begin blink_cnt<=0; led<=~led; end else blink_cnt<=blink_cnt+1; end
        2: begin if (blink_cnt>=BLINK_FAST_TOP) begin blink_cnt<=0; led<=~led; end else blink_cnt<=blink_cnt+1; end
        default: blink_cnt<=0;
    endcase
end

localparam TICK_TOP = 50_000_000;
reg [25:0] tick_cnt=0;
reg [9:0]  seconds=0;
always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin tick_cnt<=0; seconds<=0; end
    else begin
        if (tick_cnt>=TICK_TOP-1) begin tick_cnt<=0; seconds<=(seconds>=999)?0:seconds+1; end
        else tick_cnt<=tick_cnt+1;
    end
end

// Digit extraction registers
reg [9:0]  snap=0;
reg [9:0]  snap_work=0;
reg [3:0]  dig_h_val=0, dig_t_val=0, dig_o_val=0;
reg [7:0]  digit_h=0, digit_t=0, digit_o=0;
reg [1:0]  digit_count=0;
reg [7:0]  digit_byte=0;
reg        digit_req=0;
reg [1:0]  digit_idx=0;
reg [7:0]  hex_result=0;

// ─── HyperRAM IO — CC_IOBUF at 1.8V for WB bank ─────────────────────────────
reg  [7:0] dq_out=0;
wire [7:0] dq_in;
reg        dq_oe=0;
reg        rwds_out=0, rwds_oe=0;
wire       rwds_in;

CC_IOBUF #(.V_IO("1.8")) dq_iobuf_0(.A(dq_out[0]),.T(~dq_oe),.Y(dq_in[0]),.IO(hram_dq[0]));
CC_IOBUF #(.V_IO("1.8")) dq_iobuf_1(.A(dq_out[1]),.T(~dq_oe),.Y(dq_in[1]),.IO(hram_dq[1]));
CC_IOBUF #(.V_IO("1.8")) dq_iobuf_2(.A(dq_out[2]),.T(~dq_oe),.Y(dq_in[2]),.IO(hram_dq[2]));
CC_IOBUF #(.V_IO("1.8")) dq_iobuf_3(.A(dq_out[3]),.T(~dq_oe),.Y(dq_in[3]),.IO(hram_dq[3]));
CC_IOBUF #(.V_IO("1.8")) dq_iobuf_4(.A(dq_out[4]),.T(~dq_oe),.Y(dq_in[4]),.IO(hram_dq[4]));
CC_IOBUF #(.V_IO("1.8")) dq_iobuf_5(.A(dq_out[5]),.T(~dq_oe),.Y(dq_in[5]),.IO(hram_dq[5]));
CC_IOBUF #(.V_IO("1.8")) dq_iobuf_6(.A(dq_out[6]),.T(~dq_oe),.Y(dq_in[6]),.IO(hram_dq[6]));
CC_IOBUF #(.V_IO("1.8")) dq_iobuf_7(.A(dq_out[7]),.T(~dq_oe),.Y(dq_in[7]),.IO(hram_dq[7]));
CC_IOBUF #(.V_IO("1.8")) rwds_iobuf(.A(rwds_out),.T(~rwds_oe),.Y(rwds_in),.IO(hram_rwds));

// Registered DQ input — breaks the async timing path
reg [7:0] dq_in_r = 0;
always @(posedge clk_fast) dq_in_r <= dq_in;

// Control outputs — explicit CC_OBUF at 1.8V
reg hram_cs_n_r  = 1;
reg hram_rst_n_r = 0;
CC_OBUF #(.V_IO("1.8")) cs_obuf (.A(hram_cs_n_r), .O(hram_cs_n));
CC_OBUF #(.V_IO("1.8")) rst_obuf(.A(hram_rst_n_r),.O(hram_rst_n));

reg clk_en = 0;
wire clk_out = clk_en ? clk_fast_90 : 1'b0;

CC_OBUF #(.V_IO("1.8")) clkp_obuf(.A(clk_out),  .O(hram_clk_p));
CC_OBUF #(.V_IO("1.8")) clkn_obuf(.A(~clk_out), .O(hram_clk_n));

// ─── HyperRAM controller ─────────────────────────────────────────────────────
reg        hram_req=0, hram_write=0;
reg [23:0] hram_addr=0;
reg [7:0]  hram_wdata=0, hram_rdata=0;
reg        hram_done=0, hram_err=0;

localparam INIT_CYCLES=10000, LATENCY_COUNT=6;
reg [47:0] ca_reg=0;
reg [2:0]  ca_idx=0;

localparam HR_IDLE=4'd0,HR_INIT=4'd1,HR_START=4'd2,HR_CA=4'd3,
           HR_LATENCY=4'd4,HR_WRITE=4'd5,HR_WRITE2 = 4'd10,HR_READ=4'd6,HR_READ2=4'd9,
           HR_END=4'd7,HR_DONE=4'd8;
reg [3:0]  hr_state=HR_IDLE;
reg [13:0] hr_cnt=0;
reg [3:0]  lat_cnt=0;
reg        hr_init_done=0;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
        hr_state<=HR_IDLE; hram_cs_n_r<=1; hram_rst_n_r<=0;
        clk_en<=0; dq_oe<=0; rwds_oe<=0;
        hram_done<=0; hram_err<=0; hr_init_done<=0; hr_cnt<=0;
    end else begin
        hram_done<=0; hram_err<=0;
        case (hr_state)
            HR_IDLE: begin
                hram_cs_n_r<=1; clk_en<=0; dq_oe<=0; rwds_oe<=0;
                if (!hr_init_done) begin
                    hram_rst_n_r<=0; hr_cnt<=0; hr_state<=HR_INIT;
                end else if (hram_req) begin
                    ca_reg <= {
                        hram_write ? 1'b0 : 1'b1,  // bit47: R/W
                        1'b1,                        // bit46: memory space
                        1'b0,                        // bit45: linear burst
                        1'b0,                        // bit44: reserved
                        hram_addr[22:3],             // bits43-24: row address (20 bits)
                        8'b0,                        // bits23-16: reserved
                        hram_addr[2:0],              // bits15-13: col address upper
                        10'b0,                       // bits12-3: col address lower (for byte access)
                        3'b0                         // bits2-0: word within burst
                    };
                    ca_idx<=0; hr_state<=HR_START;
                end
            end
            HR_INIT: begin
                if (hr_cnt<100) begin hram_rst_n_r<=0; hr_cnt<=hr_cnt+1; end
                else if (hr_cnt<INIT_CYCLES) begin hram_rst_n_r<=1; hr_cnt<=hr_cnt+1; end
                else begin hr_init_done<=1; hr_state<=HR_IDLE; end
            end
            HR_START: begin
                hram_cs_n_r<=0; clk_en<=1;
                hr_state<=HR_CA; ca_idx<=0;
            end
                HR_CA: begin
                    dq_oe<=1; rwds_oe<=0;
                    dq_out<=ca_reg[47:40];
                    if (ca_idx<5) begin
                        ca_reg<=ca_reg<<8;
                        ca_idx<=ca_idx+1;
                    end else begin
                        lat_cnt<=0;
                        hr_state<=HR_LATENCY;
                    end
                end
            HR_LATENCY: begin
                dq_oe<=0;
                if (lat_cnt<LATENCY_COUNT-1) lat_cnt<=lat_cnt+1;
                else begin
                    if (hram_write) begin
                        dq_out<=hram_wdata; dq_oe<=1;
                        rwds_out<=0; rwds_oe<=1;
                        hr_state<=HR_WRITE;
                    end else begin
                        dq_oe<=0; rwds_oe<=0; hr_state<=HR_READ;
                    end
                end
            end
            HR_WRITE:  begin
                dq_out <= hram_wdata;  // rising edge data
                hr_state <= HR_WRITE2;
            end
            HR_WRITE2: begin
                dq_out <= hram_wdata;  // falling edge data  
                hr_state <= HR_END;
            end
            HR_READ:   hr_state<=HR_READ2;
            HR_READ2:  begin hram_rdata<=dq_in_r; hr_state<=HR_END; end
            HR_END:    begin hram_cs_n_r<=1; clk_en<=0; dq_oe<=0; rwds_oe<=0; hr_state<=HR_DONE; end
            HR_DONE:   begin hram_done<=1; hr_state<=HR_IDLE; end
        endcase
    end
end

// ─── Parser ──────────────────────────────────────────────────────────────────
localparam PARSE_IDLE=4'd0, PARSE_EXEC=4'd1, PARSE_WAIT=4'd2,
           PARSE_SNAP=4'd3, PARSE_COUNT=4'd4, PARSE_CEND=4'd5,
           PARSE_HRAM=4'd6, PARSE_HEXHI=4'd7, PARSE_HEXLO=4'd8,
           PARSE_SNPT=4'd9, PARSE_SNPO=4'd10;
reg [3:0] parse_state=PARSE_IDLE;
reg       resp_req=0;
reg [8:0] resp_addr=0;
reg       tx_busy=0;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
        parse_state<=PARSE_IDLE; resp_req<=0; digit_req<=0;
        cmd_done<=0; blink_mode<=0; led_direct<=1;
        snap<=0; digit_idx<=0; hram_req<=0;
    end else begin
        cmd_done<=0; resp_req<=0; digit_req<=0; hram_req<=0;
        case (parse_state)
            PARSE_IDLE: begin
                if (cmd_ready) begin
                    if      (is_led_on)     begin blink_mode<=0; led_direct<=0; resp_addr<=0;   parse_state<=PARSE_EXEC; end
                    else if (is_led_off)    begin blink_mode<=0; led_direct<=1; resp_addr<=20;  parse_state<=PARSE_EXEC; end
                    else if (is_status)     begin resp_addr<=40;  parse_state<=PARSE_EXEC; end
                    else if (is_clkinfo)    begin resp_addr<=60;  parse_state<=PARSE_EXEC; end
                    else if (is_blink_slow) begin blink_mode<=1; resp_addr<=90;  parse_state<=PARSE_EXEC; end
                    else if (is_blink_fast) begin blink_mode<=2; resp_addr<=110; parse_state<=PARSE_EXEC; end
                    else if (is_blink_off)  begin blink_mode<=0; led_direct<=1; resp_addr<=130; parse_state<=PARSE_EXEC; end
                    else if (is_count)      begin snap<=seconds; parse_state<=PARSE_SNAP; end
                    else if (is_write) begin
                        hram_addr<={16'b0,hex_to_val(cmd_buf[6]),hex_to_val(cmd_buf[7])};
                        hram_wdata<={hex_to_val(cmd_buf[9]),hex_to_val(cmd_buf[10])};
                        hram_write<=1; hram_req<=1; parse_state<=PARSE_HRAM;
                    end
                    else if (is_read) begin
                        hram_addr<={16'b0,hex_to_val(cmd_buf[5]),hex_to_val(cmd_buf[6])};
                        hram_write<=0; hram_req<=1; parse_state<=PARSE_HRAM;
                    end
                    else if (is_help)       begin resp_addr<=170; parse_state<=PARSE_EXEC; end
                    else                    begin resp_addr<=290; parse_state<=PARSE_EXEC; end
                end
            end
            PARSE_SNAP: begin
                snap_work<=snap; dig_h_val<=0; dig_t_val<=0; dig_o_val<=0;
                parse_state<=PARSE_SNPT;
            end
            PARSE_SNPT: begin
                if (snap_work>=100) begin snap_work<=snap_work-100; dig_h_val<=dig_h_val+1; end
                else parse_state<=PARSE_SNPO;
            end
            PARSE_SNPO: begin
                if (snap_work>=10) begin snap_work<=snap_work-10; dig_t_val<=dig_t_val+1; end
                else begin
                    digit_h<=dig_h_val+8'h30; digit_t<=dig_t_val+8'h30;
                    digit_o<=snap_work[3:0]+8'h30;
                    if (dig_h_val>0)      digit_count<=2'd3;
                    else if (dig_t_val>0) digit_count<=2'd2;
                    else                  digit_count<=2'd1;
                    resp_addr<=150; parse_state<=PARSE_EXEC;
                end
            end
            PARSE_EXEC: begin
                if (!tx_busy) begin resp_req<=1; parse_state<=PARSE_WAIT; end
            end
            PARSE_WAIT: begin
                resp_req<=0;
                if (!tx_busy && !resp_req) begin
                    if      (resp_addr==150) begin digit_idx<=0; parse_state<=PARSE_COUNT; end
                    else if (resp_addr==310||resp_addr==325) parse_state<=PARSE_HEXHI;
                    else if (resp_addr==160) begin cmd_done<=1; parse_state<=PARSE_IDLE; end
                    else                     begin cmd_done<=1; parse_state<=PARSE_IDLE; end
                end
            end
            PARSE_COUNT: begin
                if (!tx_busy && !digit_req) begin
                    case (digit_idx)
                        0: begin
                            if      (digit_count==3) digit_byte<=digit_h;
                            else if (digit_count==2) digit_byte<=digit_t;
                            else                     digit_byte<=digit_o;
                            digit_req<=1; digit_idx<=digit_idx+1;
                        end
                        1: begin
                            if (digit_count>=2) begin
                                digit_byte<=(digit_count==3)?digit_t:digit_o;
                                digit_req<=1;
                            end
                            digit_idx<=digit_idx+1;
                        end
                        2: begin
                            if (digit_count==3) begin digit_byte<=digit_o; digit_req<=1; end
                            digit_idx<=digit_idx+1;
                        end
                        3: begin resp_addr<=160; parse_state<=PARSE_CEND; end
                    endcase
                end
            end
            PARSE_CEND: begin
                if (!tx_busy) begin resp_req<=1; parse_state<=PARSE_WAIT; end
            end
            PARSE_HRAM: begin
                hram_req<=0;
                if (hram_done) begin
                    hex_result<=hram_write?hram_wdata:hram_rdata;
                    resp_addr<=hram_write?9'd310:9'd325;
                    parse_state<=PARSE_EXEC;
                end else if (hram_err) begin
                    resp_addr<=340; parse_state<=PARSE_EXEC;
                end
            end
            PARSE_HEXHI: begin
                if (!tx_busy) begin
                    digit_byte<=nibble_to_hex(hex_result[7:4]);
                    digit_req<=1; parse_state<=PARSE_HEXLO;
                end
            end
            PARSE_HEXLO: begin
                if (!tx_busy && !digit_req) begin
                    digit_byte<=nibble_to_hex(hex_result[3:0]);
                    digit_req<=1; resp_addr<=160; parse_state<=PARSE_CEND;
                end
            end
            default: parse_state<=PARSE_IDLE;
        endcase
    end
end

// ─── UART TX ─────────────────────────────────────────────────────────────────
reg [9:0]  tx_cnt=0;
reg [2:0]  tx_bit_idx=0;
reg [7:0]  tx_shift=0;
reg [8:0]  tx_addr=0;
reg [1:0]  tx_rom_mode=0;
localparam TX_IDLE=3'd0,TX_LOAD=3'd1,TX_CHECK=3'd2,
           TX_START=3'd3,TX_DATA=3'd4,TX_STOP=3'd5;
reg [2:0] tx_state=TX_IDLE;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin tx_state<=TX_IDLE; tx_busy<=0; tx<=1; end
    else begin
        case (tx_state)
            TX_IDLE: begin
                tx<=1; tx_busy<=0;
                if      (echo_req)  begin tx_shift<=echo_byte;  tx_cnt<=BIT_PERIOD-1; tx_bit_idx<=0; tx_busy<=1; tx_rom_mode<=0; tx_state<=TX_START; end
                else if (digit_req) begin tx_shift<=digit_byte; tx_cnt<=BIT_PERIOD-1; tx_bit_idx<=0; tx_busy<=1; tx_rom_mode<=0; tx_state<=TX_START; end
                else if (resp_req)  begin tx_addr<=resp_addr; tx_busy<=1; tx_rom_mode<=1; tx_state<=TX_LOAD; end
            end
            TX_LOAD:  begin tx_shift<=rom[tx_addr]; tx_state<=TX_CHECK; end
            TX_CHECK: begin
                if (tx_shift==NUL) begin tx_busy<=0; tx_state<=TX_IDLE; end
                else begin tx_cnt<=BIT_PERIOD-1; tx_bit_idx<=0; tx_state<=TX_START; end
            end
            TX_START: begin
                tx<=0;
                if (tx_cnt==0) begin tx_cnt<=BIT_PERIOD-1; tx_state<=TX_DATA; end
                else tx_cnt<=tx_cnt-1;
            end
            TX_DATA: begin
                tx<=tx_shift[0];
                if (tx_cnt==0) begin
                    tx_shift<=tx_shift>>1; tx_cnt<=BIT_PERIOD-1;
                    if (tx_bit_idx==7) tx_state<=TX_STOP; else tx_bit_idx<=tx_bit_idx+1;
                end else tx_cnt<=tx_cnt-1;
            end
            TX_STOP: begin
                tx<=1;
                if (tx_cnt==0) begin
                    case (tx_rom_mode)
                        1:       begin tx_addr<=tx_addr+1; tx_state<=TX_LOAD; end
                        default: begin tx_busy<=0; tx_state<=TX_IDLE; end
                    endcase
                end else tx_cnt<=tx_cnt-1;
            end
        endcase
    end
end

endmodule
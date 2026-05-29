module uart_cmd_V1 (
    input  wire clk,
    input  wire rx,
    output reg  tx,
    output reg  led
);

// ─── PLL ───────────────────────────────────────────────────────────────────
wire clk_fast;

CC_PLL #(
    .REF_CLK         ("10.0"),
    .OUT_CLK         ("50.0"),
    .PERF_MD         ("ECONOMY"),
    .LOW_JITTER      (1),
    .CI_FILTER_CONST (2),
    .CP_FILTER_CONST (4),
    .LOCK_REQ        (1),
    .CLK270_DOUB     (0),
    .CLK180_DOUB     (0)
) pll_inst (
    .CLK_REF             (clk),
    .CLK_FEEDBACK        (1'b0),
    .USR_CLK_REF         (1'b0),
    .USR_LOCKED_STDY_RST (1'b0),
    .USR_PLL_LOCKED_STDY (),
    .USR_PLL_LOCKED      (),
    .CLK270              (),
    .CLK180              (),
    .CLK90               (),
    .CLK0                (clk_fast),
    .CLK_REF_OUT         ()
);

// ─── Reset ─────────────────────────────────────────────────────────────────
wire usr_rstn;
CC_USR_RSTN rstn_inst (.USR_RSTN(usr_rstn));

reg rst_sync0 = 0, rst_sync1 = 0;
always @(posedge clk_fast) begin
    rst_sync0 <= usr_rstn;
    rst_sync1 <= rst_sync0;
end
wire rst_n = rst_sync1;

// ─── Parameters ────────────────────────────────────────────────────────────
parameter  CLK_FREQ  = 50_000_000;
parameter  BAUD_RATE = 57600;
localparam BIT_PERIOD  = CLK_FREQ / BAUD_RATE;
localparam HALF_PERIOD = BIT_PERIOD / 2;

// ─── ASCII constants ────────────────────────────────────────────────────────
localparam CR  = 8'h0D;
localparam LF  = 8'h0A;
localparam NUL = 8'h00;
localparam SP  = 8'h20;

// ─── RX Synchroniser ────────────────────────────────────────────────────────
reg rx_s0 = 1, rx_s1 = 1, rx_s2 = 1;
wire rx_sync = rx_s2;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
        rx_s0 <= 1; rx_s1 <= 1; rx_s2 <= 1;
    end else begin
        rx_s0 <= rx;
        rx_s1 <= rx_s0;
        rx_s2 <= rx_s1;
    end
end

// ─── UART RX ────────────────────────────────────────────────────────────────
localparam RX_IDLE  = 2'd0,
           RX_START = 2'd1,
           RX_DATA  = 2'd2,
           RX_STOP  = 2'd3;

reg [1:0]  rx_state   = RX_IDLE;
reg [9:0]  rx_cnt     = 0;
reg [2:0]  rx_bit_idx = 0;
reg [7:0]  rx_shift   = 0;
reg        rx_valid   = 0;
reg [7:0]  rx_byte    = 0;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
        rx_state <= RX_IDLE; rx_valid <= 0;
    end else begin
        rx_valid <= 0;
        case (rx_state)
            RX_IDLE:  if (rx_sync == 0) begin
                          rx_state <= RX_START;
                          rx_cnt   <= HALF_PERIOD - 1;
                      end
            RX_START: if (rx_cnt == 0) begin
                          if (rx_sync == 0) begin
                              rx_state   <= RX_DATA;
                              rx_cnt     <= BIT_PERIOD - 1;
                              rx_bit_idx <= 0;
                          end else
                              rx_state <= RX_IDLE;
                      end else rx_cnt <= rx_cnt - 1;
            RX_DATA:  if (rx_cnt == 0) begin
                          rx_shift   <= {rx_sync, rx_shift[7:1]};
                          rx_cnt     <= BIT_PERIOD - 1;
                          if (rx_bit_idx == 7) rx_state <= RX_STOP;
                          else rx_bit_idx <= rx_bit_idx + 1;
                      end else rx_cnt <= rx_cnt - 1;
            RX_STOP:  if (rx_cnt == 0) begin
                          rx_state <= RX_IDLE;
                          if (rx_sync == 1) begin
                              rx_byte  <= rx_shift;
                              rx_valid <= 1;
                          end
                      end else rx_cnt <= rx_cnt - 1;
        endcase
    end
end

// ─── Command Buffer ──────────────────────────────────────────────────────────
reg [7:0] cmd_buf [0:15];
reg [3:0] cmd_len   = 0;
reg       cmd_ready = 0;
reg       cmd_done  = 0;

function [7:0] to_upper;
    input [7:0] ch;
    begin
        if (ch >= 8'h61 && ch <= 8'h7A)
            to_upper = ch & 8'hDF;
        else
            to_upper = ch;
    end
endfunction

reg [7:0] echo_byte = 0;
reg       echo_req  = 0;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
        cmd_len <= 0; cmd_ready <= 0; echo_req <= 0;
    end else begin
        cmd_ready <= 0;
        echo_req  <= 0;
        if (rx_valid) begin
            if (rx_byte == CR || rx_byte == LF) begin
                if (cmd_len > 0) begin
                    echo_byte <= LF;
                    echo_req  <= 1;
                    cmd_ready <= 1;
                end
            end else if (cmd_len < 15) begin
                echo_byte        <= rx_byte;
                echo_req         <= 1;
                cmd_buf[cmd_len] <= to_upper(rx_byte);
                cmd_len          <= cmd_len + 1;
            end
        end
        if (cmd_done) cmd_len <= 0;
    end
end

// ─── Response ROM ────────────────────────────────────────────────────────────
reg [7:0] rom [0:287];

initial begin
    // ROM[0] "LED ON\r\n"
    rom[0]="L";  rom[1]="E";  rom[2]="D";  rom[3]=" ";
    rom[4]="O";  rom[5]="N";  rom[6]="\r"; rom[7]="\n";
    rom[8]=NUL;

    // ROM[20] "LED OFF\r\n"
    rom[20]="L"; rom[21]="E"; rom[22]="D"; rom[23]=" ";
    rom[24]="O"; rom[25]="F"; rom[26]="F"; rom[27]="\r";
    rom[28]="\n"; rom[29]=NUL;

    // ROM[40] "GateMate OK\r\n"
    rom[40]="G"; rom[41]="a"; rom[42]="t"; rom[43]="e";
    rom[44]="M"; rom[45]="a"; rom[46]="t"; rom[47]="e";
    rom[48]=" "; rom[49]="O"; rom[50]="K"; rom[51]="\r";
    rom[52]="\n"; rom[53]=NUL;

    // ROM[60] "CLK: 50MHz - PLL LOCKED\r\n"
    rom[60]="C";  rom[61]="L";  rom[62]="K";  rom[63]=":";
    rom[64]=" ";  rom[65]="5";  rom[66]="0";  rom[67]="M";
    rom[68]="H";  rom[69]="z";  rom[70]=" ";  rom[71]="-";
    rom[72]=" ";  rom[73]="P";  rom[74]="L";  rom[75]="L";
    rom[76]=" ";  rom[77]="L";  rom[78]="O";  rom[79]="C";
    rom[80]="K";  rom[81]="E";  rom[82]="D";  rom[83]="\r";
    rom[84]="\n"; rom[85]=NUL;

    // ROM[90] "Blinking: SLOW\r\n"
    rom[90]="B";  rom[91]="l";  rom[92]="i";  rom[93]="n";
    rom[94]="k";  rom[95]="i";  rom[96]="n";  rom[97]="g";
    rom[98]=":";  rom[99]=" ";  rom[100]="S"; rom[101]="L";
    rom[102]="O"; rom[103]="W"; rom[104]="\r";rom[105]="\n";
    rom[106]=NUL;

    // ROM[110] "Blinking: FAST\r\n"
    rom[110]="B"; rom[111]="l"; rom[112]="i"; rom[113]="n";
    rom[114]="k"; rom[115]="i"; rom[116]="n"; rom[117]="g";
    rom[118]=":"; rom[119]=" "; rom[120]="F"; rom[121]="A";
    rom[122]="S"; rom[123]="T"; rom[124]="\r";rom[125]="\n";
    rom[126]=NUL;

    // ROM[130] "Blinking: OFF\r\n"
    rom[130]="B"; rom[131]="l"; rom[132]="i"; rom[133]="n";
    rom[134]="k"; rom[135]="i"; rom[136]="n"; rom[137]="g";
    rom[138]=":"; rom[139]=" "; rom[140]="O"; rom[141]="F";
    rom[142]="F"; rom[143]="\r";rom[144]="\n";rom[145]=NUL;

    // ROM[150] "Counter: "
    rom[150]="C"; rom[151]="o"; rom[152]="u"; rom[153]="n";
    rom[154]="t"; rom[155]="e"; rom[156]="r"; rom[157]=":";
    rom[158]=" "; rom[159]=NUL;

    // ROM[160] "\r\n"
    rom[160]="\r"; rom[161]="\n"; rom[162]=NUL;

    // ROM[170] HELP text
    rom[170]="C"; rom[171]="o"; rom[172]="m"; rom[173]="m";
    rom[174]="a"; rom[175]="n"; rom[176]="d"; rom[177]="s";
    rom[178]=":"; rom[179]="\r";rom[180]="\n";
    rom[181]=" "; rom[182]="L"; rom[183]="E"; rom[184]="D";
    rom[185]=" "; rom[186]="O"; rom[187]="N"; rom[188]="\r";
    rom[189]="\n";
    rom[190]=" "; rom[191]="L"; rom[192]="E"; rom[193]="D";
    rom[194]=" "; rom[195]="O"; rom[196]="F"; rom[197]="F";
    rom[198]="\r";rom[199]="\n";
    rom[200]=" "; rom[201]="B"; rom[202]="L"; rom[203]="I";
    rom[204]="N"; rom[205]="K"; rom[206]=" "; rom[207]="S";
    rom[208]="L"; rom[209]="O"; rom[210]="W"; rom[211]="\r";
    rom[212]="\n";
    rom[213]=" "; rom[214]="B"; rom[215]="L"; rom[216]="I";
    rom[217]="N"; rom[218]="K"; rom[219]=" "; rom[220]="F";
    rom[221]="A"; rom[222]="S"; rom[223]="T"; rom[224]="\r";
    rom[225]="\n";
    rom[226]=" "; rom[227]="B"; rom[228]="L"; rom[229]="I";
    rom[230]="N"; rom[231]="K"; rom[232]=" "; rom[233]="O";
    rom[234]="F"; rom[235]="F"; rom[236]="\r";rom[237]="\n";
    rom[238]=" "; rom[239]="C"; rom[240]="O"; rom[241]="U";
    rom[242]="N"; rom[243]="T"; rom[244]="\r";rom[245]="\n";
    rom[246]=" "; rom[247]="S"; rom[248]="T"; rom[249]="A";
    rom[250]="T"; rom[251]="U"; rom[252]="S"; rom[253]="\r";
    rom[254]="\n";
    rom[255]=" "; rom[256]="H"; rom[257]="E"; rom[258]="L";
    rom[259]="P"; rom[260]="\r";rom[261]="\n";rom[262]=NUL;

    // ROM[270] "Unknown command\r\n"
    rom[270]="U"; rom[271]="n"; rom[272]="k"; rom[273]="n";
    rom[274]="o"; rom[275]="w"; rom[276]="n"; rom[277]=" ";
    rom[278]="c"; rom[279]="o"; rom[280]="m"; rom[281]="m";
    rom[282]="a"; rom[283]="n"; rom[284]="d"; rom[285]="\r";
    rom[286]="\n";rom[287]=NUL;
end

// ─── Command matching wires ──────────────────────────────────────────────────
wire is_led_on  = (cmd_len==6) &&
                  cmd_buf[0]=="L" && cmd_buf[1]=="E" &&
                  cmd_buf[2]=="D" && cmd_buf[3]==" " &&
                  cmd_buf[4]=="O" && cmd_buf[5]=="N";

wire is_led_off = (cmd_len==7) &&
                  cmd_buf[0]=="L" && cmd_buf[1]=="E" &&
                  cmd_buf[2]=="D" && cmd_buf[3]==" " &&
                  cmd_buf[4]=="O" && cmd_buf[5]=="F" &&
                  cmd_buf[6]=="F";

wire is_status  = (cmd_len==6) &&
                  cmd_buf[0]=="S" && cmd_buf[1]=="T" &&
                  cmd_buf[2]=="A" && cmd_buf[3]=="T" &&
                  cmd_buf[4]=="U" && cmd_buf[5]=="S";

wire is_clkinfo = (cmd_len==7) &&
                  cmd_buf[0]=="C" && cmd_buf[1]=="L" &&
                  cmd_buf[2]=="K" && cmd_buf[3]=="I" &&
                  cmd_buf[4]=="N" && cmd_buf[5]=="F" &&
                  cmd_buf[6]=="O";

wire is_help    = (cmd_len==4) &&
                  cmd_buf[0]=="H" && cmd_buf[1]=="E" &&
                  cmd_buf[2]=="L" && cmd_buf[3]=="P";

wire is_blink_slow = (cmd_len==10) &&
                     cmd_buf[0]=="B" && cmd_buf[1]=="L" &&
                     cmd_buf[2]=="I" && cmd_buf[3]=="N" &&
                     cmd_buf[4]=="K" && cmd_buf[5]==" " &&
                     cmd_buf[6]=="S" && cmd_buf[7]=="L" &&
                     cmd_buf[8]=="O" && cmd_buf[9]=="W";

wire is_blink_fast = (cmd_len==10) &&
                     cmd_buf[0]=="B" && cmd_buf[1]=="L" &&
                     cmd_buf[2]=="I" && cmd_buf[3]=="N" &&
                     cmd_buf[4]=="K" && cmd_buf[5]==" " &&
                     cmd_buf[6]=="F" && cmd_buf[7]=="A" &&
                     cmd_buf[8]=="S" && cmd_buf[9]=="T";

wire is_blink_off  = (cmd_len==9) &&
                     cmd_buf[0]=="B" && cmd_buf[1]=="L" &&
                     cmd_buf[2]=="I" && cmd_buf[3]=="N" &&
                     cmd_buf[4]=="K" && cmd_buf[5]==" " &&
                     cmd_buf[6]=="O" && cmd_buf[7]=="F" &&
                     cmd_buf[8]=="F";

wire is_count      = (cmd_len==5) &&
                     cmd_buf[0]=="C" && cmd_buf[1]=="O" &&
                     cmd_buf[2]=="U" && cmd_buf[3]=="N" &&
                     cmd_buf[4]=="T";

// ─── LED direct register ─────────────────────────────────────────────────────
reg led_direct = 1;

// ─── Blink timer ─────────────────────────────────────────────────────────────
reg [1:0]  blink_mode = 0;
reg [25:0] blink_cnt  = 0;

localparam BLINK_SLOW_TOP = 25_000_000;
localparam BLINK_FAST_TOP =  2_500_000;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
        blink_cnt <= 0;
        led       <= 1;
    end else begin
        case (blink_mode)
            0: begin
                led       <= led_direct;
                blink_cnt <= 0;
            end
            1: begin
                if (blink_cnt >= BLINK_SLOW_TOP) begin
                    blink_cnt <= 0;
                    led       <= ~led;
                end else
                    blink_cnt <= blink_cnt + 1;
            end
            2: begin
                if (blink_cnt >= BLINK_FAST_TOP) begin
                    blink_cnt <= 0;
                    led       <= ~led;
                end else
                    blink_cnt <= blink_cnt + 1;
            end
            default: blink_cnt <= 0;
        endcase
    end
end

// ─── Free running seconds counter ────────────────────────────────────────────
localparam TICK_TOP = 50_000_000;

reg [25:0] tick_cnt = 0;
reg [9:0]  seconds  = 0;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
        tick_cnt <= 0;
        seconds  <= 0;
    end else begin
        if (tick_cnt >= TICK_TOP - 1) begin
            tick_cnt <= 0;
            if (seconds >= 999)
                seconds <= 0;
            else
                seconds <= seconds + 1;
        end else begin
            tick_cnt <= tick_cnt + 1;
        end
    end
end

// ─── Digit extraction registers (all at module level) ────────────────────────
reg [9:0]  snap        = 0;  // snapshot of seconds
reg [7:0]  digit_h     = 0;  // hundreds ASCII
reg [7:0]  digit_t     = 0;  // tens ASCII
reg [7:0]  digit_o     = 0;  // ones ASCII
reg [1:0]  digit_count = 0;  // how many digits: 1, 2, or 3
reg [7:0]  digit_byte  = 0;  // current digit byte being sent
reg        digit_req   = 0;  // request TX to send digit_byte
reg [1:0]  digit_idx   = 0;  // which digit we are on: 0=first, 3=done

// ─── Parser ──────────────────────────────────────────────────────────────────
// State encoding — 3 bits needed for 6 states
localparam PARSE_IDLE  = 3'd0,
           PARSE_EXEC  = 3'd1,
           PARSE_WAIT  = 3'd2,
           PARSE_SNAP  = 3'd3,  // one cycle after snapshot
           PARSE_COUNT = 3'd4,  // sending digits
           PARSE_CEND  = 3'd5;  // sending final \r\n

reg [2:0]  parse_state = PARSE_IDLE;
reg        resp_req    = 0;
reg [8:0]  resp_addr   = 0;
reg        tx_busy     = 0;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
        parse_state <= PARSE_IDLE;
        resp_req    <= 0;
        digit_req   <= 0;
        cmd_done    <= 0;
        blink_mode  <= 0;
        led_direct  <= 1;
        snap        <= 0;
        digit_idx   <= 0;
    end else begin
        cmd_done  <= 0;
        resp_req  <= 0;
        digit_req <= 0;

        case (parse_state)

            PARSE_IDLE: begin
                if (cmd_ready) begin
                    if (is_led_on) begin
                        blink_mode  <= 0;
                        led_direct  <= 0;
                        resp_addr   <= 0;
                        parse_state <= PARSE_EXEC;
                    end else if (is_led_off) begin
                        blink_mode  <= 0;
                        led_direct  <= 1;
                        resp_addr   <= 20;
                        parse_state <= PARSE_EXEC;
                    end else if (is_status) begin
                        resp_addr   <= 40;
                        parse_state <= PARSE_EXEC;
                    end else if (is_clkinfo) begin
                        resp_addr   <= 60;
                        parse_state <= PARSE_EXEC;
                    end else if (is_blink_slow) begin
                        blink_mode  <= 1;
                        resp_addr   <= 90;
                        parse_state <= PARSE_EXEC;
                    end else if (is_blink_fast) begin
                        blink_mode  <= 2;
                        resp_addr   <= 110;
                        parse_state <= PARSE_EXEC;
                    end else if (is_blink_off) begin
                        blink_mode  <= 0;
                        led_direct  <= 1;
                        resp_addr   <= 130;
                        parse_state <= PARSE_EXEC;
                    end else if (is_count) begin
                        // Step 1: snapshot seconds into register
                        // We cannot use snap until next cycle because
                        // registers update at end of clock cycle
                        snap        <= seconds;
                        parse_state <= PARSE_SNAP;
                    end else if (is_help) begin
                        resp_addr   <= 170;
                        parse_state <= PARSE_EXEC;
                    end else begin
                        resp_addr   <= 270;
                        parse_state <= PARSE_EXEC;
                    end
                end
            end

            PARSE_SNAP: begin
                // Step 2: snap now has stable value — extract digits
                // snap is guaranteed to be the frozen seconds value
                if (snap >= 100) begin
                    digit_h     <= (snap / 100) + 8'h30;
                    digit_t     <= ((snap % 100) / 10) + 8'h30;
                    digit_o     <= (snap % 10) + 8'h30;
                    digit_count <= 2'd3;
                end else if (snap >= 10) begin
                    digit_h     <= 0;
                    digit_t     <= (snap / 10) + 8'h30;
                    digit_o     <= (snap % 10) + 8'h30;
                    digit_count <= 2'd2;
                end else begin
                    digit_h     <= 0;
                    digit_t     <= 0;
                    digit_o     <= snap + 8'h30;
                    digit_count <= 2'd1;
                end
                // Send "Counter: " header first
                resp_addr   <= 150;
                parse_state <= PARSE_EXEC;
            end

            PARSE_EXEC: begin
                // Wait for TX free then fire request
                if (!tx_busy) begin
                    resp_req    <= 1;
                    parse_state <= PARSE_WAIT;
                end
            end

            PARSE_WAIT: begin
                resp_req <= 0;
                if (!tx_busy && !resp_req) begin
                    // Check what we just finished sending
                    if (resp_addr == 150) begin
                        // Just sent "Counter: " header
                        // Now send the digits
                        digit_idx   <= 0;
                        parse_state <= PARSE_COUNT;
                    end else if (resp_addr == 160) begin
                        // Just sent "\r\n" — fully done
                        cmd_done    <= 1;
                        parse_state <= PARSE_IDLE;
                    end else begin
                        // All other commands — done
                        cmd_done    <= 1;
                        parse_state <= PARSE_IDLE;
                    end
                end
            end

            PARSE_COUNT: begin
                // Send digits one at a time
                // Wait for TX free before each digit
                if (!tx_busy && !digit_req) begin
                    case (digit_idx)
                        0: begin
                            // Send first significant digit
                            if (digit_count == 3) begin
                                digit_byte <= digit_h;
                            end else if (digit_count == 2) begin
                                digit_byte <= digit_t;
                            end else begin
                                digit_byte <= digit_o;
                            end
                            digit_req <= 1;
                            digit_idx <= digit_idx + 1;
                        end
                        1: begin
                            // Second digit if count >= 2
                            if (digit_count >= 2) begin
                                if (digit_count == 3)
                                    digit_byte <= digit_t;
                                else
                                    digit_byte <= digit_o;
                                digit_req <= 1;
                            end
                            digit_idx <= digit_idx + 1;
                        end
                        2: begin
                            // Third digit if count == 3
                            if (digit_count == 3) begin
                                digit_byte <= digit_o;
                                digit_req  <= 1;
                            end
                            digit_idx <= digit_idx + 1;
                        end
                        3: begin
                            // All digits sent — send "\r\n"
                            resp_addr   <= 160;
                            parse_state <= PARSE_CEND;
                        end
                    endcase
                end
            end

            PARSE_CEND: begin
                // Send the final "\r\n" from ROM then done
                if (!tx_busy) begin
                    resp_req    <= 1;
                    parse_state <= PARSE_WAIT;
                end
            end

        endcase
    end
end

// ─── UART TX ─────────────────────────────────────────────────────────────────
reg [9:0]  tx_cnt      = 0;
reg [2:0]  tx_bit_idx  = 0;
reg [7:0]  tx_shift    = 0;
reg [8:0]  tx_addr     = 0;
reg [1:0]  tx_rom_mode = 0;

localparam TX_IDLE  = 3'd0,
           TX_LOAD  = 3'd1,
           TX_CHECK = 3'd2,
           TX_START = 3'd3,
           TX_DATA  = 3'd4,
           TX_STOP  = 3'd5;

reg [2:0] tx_state = TX_IDLE;

always @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
        tx_state <= TX_IDLE;
        tx_busy  <= 0;
        tx       <= 1;
    end else begin
        case (tx_state)
            TX_IDLE: begin
                tx      <= 1;
                tx_busy <= 0;
                if (echo_req) begin
                    tx_shift    <= echo_byte;
                    tx_cnt      <= BIT_PERIOD - 1;
                    tx_bit_idx  <= 0;
                    tx_busy     <= 1;
                    tx_rom_mode <= 0;
                    tx_state    <= TX_START;
                end else if (digit_req) begin
                    // Single digit byte — same path as echo
                    tx_shift    <= digit_byte;
                    tx_cnt      <= BIT_PERIOD - 1;
                    tx_bit_idx  <= 0;
                    tx_busy     <= 1;
                    tx_rom_mode <= 0;
                    tx_state    <= TX_START;
                end else if (resp_req) begin
                    tx_addr     <= resp_addr;
                    tx_busy     <= 1;
                    tx_rom_mode <= 1;
                    tx_state    <= TX_LOAD;
                end
            end

            TX_LOAD: begin
                tx_shift <= rom[tx_addr];
                tx_state <= TX_CHECK;
            end

            TX_CHECK: begin
                if (tx_shift == NUL) begin
                    tx_busy  <= 0;
                    tx_state <= TX_IDLE;
                end else begin
                    tx_cnt     <= BIT_PERIOD - 1;
                    tx_bit_idx <= 0;
                    tx_state   <= TX_START;
                end
            end

            TX_START: begin
                tx <= 0;
                if (tx_cnt == 0) begin
                    tx_cnt   <= BIT_PERIOD - 1;
                    tx_state <= TX_DATA;
                end else tx_cnt <= tx_cnt - 1;
            end

            TX_DATA: begin
                tx <= tx_shift[0];
                if (tx_cnt == 0) begin
                    tx_shift <= tx_shift >> 1;
                    tx_cnt   <= BIT_PERIOD - 1;
                    if (tx_bit_idx == 7) tx_state <= TX_STOP;
                    else tx_bit_idx <= tx_bit_idx + 1;
                end else tx_cnt <= tx_cnt - 1;
            end

            TX_STOP: begin
                tx <= 1;
                if (tx_cnt == 0) begin
                    case (tx_rom_mode)
                        0: begin
                            tx_busy  <= 0;
                            tx_state <= TX_IDLE;
                        end
                        1: begin
                            tx_addr  <= tx_addr + 1;
                            tx_state <= TX_LOAD;
                        end
                        default: begin
                            tx_busy  <= 0;
                            tx_state <= TX_IDLE;
                        end
                    endcase
                end else tx_cnt <= tx_cnt - 1;
            end
        endcase
    end
end

endmodule

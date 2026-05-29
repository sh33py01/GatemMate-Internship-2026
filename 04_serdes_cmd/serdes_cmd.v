module serdes_cmd (
    input  wire pll_rstn_i,
    input  wire trx_rstn_i,
    input  wire clk,
    input  wire rx,
    output reg  tx,
    output wire led,
    output wire RX_RESET_DONE_O_N,
    output wire TX_RESET_DONE_O_N,
    output wire TX_DETECT_RX_DONE_O_N,
    output wire TX_DETECT_RX_PRESENT_O_N,
    output wire RX_PRBS_ERR_O_N,
    output wire RX_BUF_ERR_O_N,
    output wire TX_BUF_ERR_O_N
);

// ─── Fabric PLL: 10→50 MHz ────────────────────────────────────────────────────
wire clk_fast;
wire PLL_CLK_O;
wire RX_CLK_O;
CC_PLL #(
    .REF_CLK("10.0"), .OUT_CLK("50.0"),
    .PERF_MD("SPEED"),
    .LOCK_REQ(1), .CLK270_DOUB(0), .CLK180_DOUB(0)
) pll_fabric (
    .CLK_REF(clk), .CLK_FEEDBACK(1'b0), .USR_CLK_REF(1'b0),
    .USR_LOCKED_STDY_RST(1'b0), .USR_PLL_LOCKED_STDY(), .USR_PLL_LOCKED(),
    .CLK270(), .CLK180(), .CLK90(), .CLK0(clk_fast), .CLK_REF_OUT()
);

// ─── UART parameters ─────────────────────────────────────────────────────────
localparam CLK_FREQ   = 50_000_000;
localparam BAUD_RATE  = 57600;
localparam BIT_PERIOD  = CLK_FREQ / BAUD_RATE;
localparam HALF_PERIOD = BIT_PERIOD / 2;
localparam CR=8'h0D, LF=8'h0A, NUL=8'h00;

// ─── UART RX ─────────────────────────────────────────────────────────────────
reg rx_s0=1, rx_s1=1, rx_s2=1;
wire rx_sync = rx_s2;
always @(posedge clk_fast) begin
    rx_s0<=rx; rx_s1<=rx_s0; rx_s2<=rx_s1;
end

localparam RX_IDLE=2'd0, RX_START=2'd1, RX_DATA=2'd2, RX_STOP=2'd3;
reg [1:0] rx_state=RX_IDLE;
reg [9:0] rx_cnt=0;
reg [2:0] rx_bit_idx=0;
reg [7:0] rx_shift=0;
reg       rx_valid=0;
reg [7:0] rx_byte=0;

always @(posedge clk_fast) begin
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

// ─── Command buffer ───────────────────────────────────────────────────────────
function [7:0] to_upper;
    input [7:0] ch;
    begin if (ch>=8'h61&&ch<=8'h7A) to_upper=ch&8'hDF; else to_upper=ch; end
endfunction

reg [7:0] cmd_buf [0:7];
reg [2:0] cmd_len=0;
reg       cmd_ready=0, cmd_done=0;
reg [7:0] echo_byte=0;
reg       echo_req=0;

always @(posedge clk_fast) begin
    cmd_ready<=0; echo_req<=0;
    if (rx_valid) begin
        if (rx_byte==CR||rx_byte==LF) begin
            if (cmd_len>0) begin echo_byte<=LF; echo_req<=1; cmd_ready<=1; end
        end else if (cmd_len<8) begin
            echo_byte<=rx_byte; echo_req<=1;
            cmd_buf[cmd_len]<=to_upper(rx_byte); cmd_len<=cmd_len+1;
        end
    end
    if (cmd_done) cmd_len<=0;
end

// ─── Command decode ───────────────────────────────────────────────────────────
wire is_prbs  = (cmd_len==4)&&cmd_buf[0]=="P"&&cmd_buf[1]=="R"&&cmd_buf[2]=="B"&&cmd_buf[3]=="S";
wire is_count = (cmd_len==5)&&cmd_buf[0]=="C"&&cmd_buf[1]=="O"&&cmd_buf[2]=="U"&&cmd_buf[3]=="N"&&cmd_buf[4]=="T";
wire is_comma = (cmd_len==5)&&cmd_buf[0]=="C"&&cmd_buf[1]=="O"&&cmd_buf[2]=="M"&&cmd_buf[3]=="M"&&cmd_buf[4]=="A";
wire is_idle  = (cmd_len==4)&&cmd_buf[0]=="I"&&cmd_buf[1]=="D"&&cmd_buf[2]=="L"&&cmd_buf[3]=="E";
wire is_status= (cmd_len==6)&&cmd_buf[0]=="S"&&cmd_buf[1]=="T"&&cmd_buf[2]=="A"&&cmd_buf[3]=="T"&&cmd_buf[4]=="U"&&cmd_buf[5]=="S";
wire is_help  = (cmd_len==4)&&cmd_buf[0]=="H"&&cmd_buf[1]=="E"&&cmd_buf[2]=="L"&&cmd_buf[3]=="P";

// tx_mode: 0=COMMA 1=PRBS 2=COUNT 3=IDLE
reg [1:0] tx_mode = 0;

// ─── SerDes TX data mux ───────────────────────────────────────────────────────
reg [63:0] tx_counter = 0;
always @(posedge clk_fast) tx_counter <= tx_counter + 1;

reg [63:0] serdes_tx_data;
reg [7:0]  serdes_tx_k;
reg [2:0]  serdes_prbs_sel;
reg        serdes_elec_idle;
reg        serdes_8b10b_en;

always @(*) begin
    case (tx_mode)
        0: begin // COMMA
            serdes_tx_data   = 64'hBCBCBCBCBCBCBCBC;
            serdes_tx_k      = 8'hFF;
            serdes_prbs_sel  = 3'b000;
            serdes_elec_idle = 1'b0;
            serdes_8b10b_en  = 1'b1;
        end
        1: begin // PRBS-7
            serdes_tx_data   = 64'h0;
            serdes_tx_k      = 8'h0;
            serdes_prbs_sel  = 3'b001;
            serdes_elec_idle = 1'b0;
            serdes_8b10b_en  = 1'b0;
        end
        2: begin // COUNTER
            serdes_tx_data   = tx_counter;
            serdes_tx_k      = 8'h0;
            serdes_prbs_sel  = 3'b000;
            serdes_elec_idle = 1'b0;
            serdes_8b10b_en  = 1'b0;
        end
        default: begin // IDLE
            serdes_tx_data   = 64'h0;
            serdes_tx_k      = 8'h0;
            serdes_prbs_sel  = 3'b000;
            serdes_elec_idle = 1'b1;
            serdes_8b10b_en  = 1'b0;
        end
    endcase
end

// ─── SerDes instance ──────────────────────────────────────────────────────────
wire [63:0] RX_DATA_O;
wire trx_rst_i = ~trx_rstn_i;
wire pll_rst_i = ~pll_rstn_i;
wire [7:0] rx_char_is_comma;
wire [7:0] rx_char_is_k;
wire TX_RESET_DONE_O, RX_RESET_DONE_O;
assign TX_RESET_DONE_O_N = ~TX_RESET_DONE_O;
assign RX_RESET_DONE_O_N = ~RX_RESET_DONE_O;
wire TX_DETECT_RX_PRESENT_O, TX_DETECT_RX_DONE_O;
assign TX_DETECT_RX_PRESENT_O_N = ~TX_DETECT_RX_PRESENT_O;
assign TX_DETECT_RX_DONE_O_N    = ~TX_DETECT_RX_DONE_O;
wire RX_PRBS_ERR_O, TX_BUF_ERR_O, RX_BUF_ERR_O;
assign RX_PRBS_ERR_O_N = ~RX_PRBS_ERR_O;
assign TX_BUF_ERR_O_N  = ~TX_BUF_ERR_O;
assign RX_BUF_ERR_O_N  = ~RX_BUF_ERR_O;
wire RX_EI_EN_O, REGFILE_RDY_O;
wire [15:0] REGFILE_DO_O;
wire [7:0] RX_NOT_IN_TABLE_O;

parameter [1:0] DATAPATH_SEL    = 2'b11;
parameter [5:0] PLL_FCNTRL      = 6'h3A;
parameter [5:0] PLL_MAIN_DIVSEL = 6'h1B;
parameter [1:0] PLL_OUT_DIVSEL  = 2'b11;
parameter [1:0] TX_PMA_LOOPBACK = 2'b00;

CC_SERDES #(
    .RX_BUF_RESET_TIME(5'h3), .RX_PCS_RESET_TIME(5'h3),
    .RX_RESET_TIMER_PRESC(5'h0), .RX_RESET_DONE_GATE(1'h0),
    .RX_CDR_RESET_TIME(5'h3), .RX_EQA_RESET_TIME(5'h3),
    .RX_PMA_RESET_TIME(5'h3), .RX_WAIT_CDR_LOCK(1'b0),
    .RX_CALIB_EN(1'h0), .RX_CALIB_OVR(1'h0), .RX_CALIB_VAL(4'h0),
    .RX_RTERM_VCMSEL(3'h4), .RX_RTERM_PD(1'h0),
    .RX_EQA_CKP_LF(8'hA3), .RX_EQA_CKP_HF(8'hA3),
    .RX_EQA_CKP_OFFSET(8'h01), .RX_EN_EQA(1'h0),
    .RX_EQA_LOCK_CFG(4'h0), .RX_TH_MON1(5'h8),
    .RX_EN_EQA_EXT_VALUE(4'h0), .RX_TH_MON2(5'h8),
    .RX_TAPW(5'h8), .RX_AFE_OFFSET(5'h8),
    .RX_EQA_CONFIG(16'h1C0), .RX_AFE_PEAK(5'hF),
    .RX_AFE_GAIN(4'h8), .RX_AFE_VCMSEL(3'h4),
    .RX_CDR_CKP(8'hF8), .RX_CDR_CKI(8'h00),
    .RX_CDR_TRANS_TH(9'h80), .RX_CDR_LOCK_CFG(6'hB),
    .RX_CDR_FREQ_ACC(15'h0), .RX_CDR_PHASE_ACC(16'h0),
    .RX_CDR_SET_ACC_CONFIG(2'h0), .RX_CDR_FORCE_LOCK(1'h0),
    .RX_ALIGN_MCOMMA_VALUE(10'h283), .RX_MCOMMA_ALIGN_OVR(1'h0),
    .RX_MCOMMA_ALIGN(1'h0),
    .RX_ALIGN_PCOMMA_VALUE(10'h17C), .RX_PCOMMA_ALIGN_OVR(1'h0),
    .RX_PCOMMA_ALIGN(1'h0),
    .RX_ALIGN_COMMA_WORD(2'h3), .RX_ALIGN_COMMA_ENABLE(10'h3FF),
    .RX_SLIDE_MODE(2'b00), .RX_COMMA_DETECT_EN_OVR(1'h0),
    .RX_COMMA_DETECT_EN(1'h0), .RX_SLIDE(2'h0),
    .RX_EYE_MEAS_EN(1'h0), .RX_EYE_MEAS_CFG(15'h0),
    .RX_MON_PH_OFFSET(6'h0), .RX_EI_BIAS(4'h4),
    .RX_EI_BW_SEL(4'h4), .RX_EN_EI_DETECTOR_OVR(1'h0),
    .RX_EN_EI_DETECTOR(1'h0), .RX_DATA_SEL(1'h0),
    .RX_BUF_BYPASS(1'h0), .RX_CLKCOR_USE(1'h0),
    .RX_CLKCOR_MIN_LAT(6'h20), .RX_CLKCOR_MAX_LAT(6'h27),
    .RX_CLKCOR_SEQ_1_0(10'h1F7), .RX_CLKCOR_SEQ_1_1(10'h1F7),
    .RX_CLKCOR_SEQ_1_2(10'h1F7), .RX_CLKCOR_SEQ_1_3(10'h1F7),
    .RX_PMA_LOOPBACK(1'h0), .RX_PCS_LOOPBACK(1'h0),
    .RX_DATAPATH_SEL(DATAPATH_SEL), .RX_PRBS_OVR(1'h0),
    .RX_PRBS_SEL(3'b0), .RX_LOOPBACK_OVR(1'h0),
    .RX_PRBS_CNT_RESET(1'h0), .RX_POWER_DOWN_OVR(1'h0),
    .RX_POWER_DOWN_N(1'h0), .RX_RESET_OVR(1'h0), .RX_RESET(1'h0),
    .RX_PMA_RESET_OVR(1'h0), .RX_PMA_RESET(1'h0),
    .RX_EQA_RESET_OVR(1'h0), .RX_EQA_RESET(1'h0),
    .RX_CDR_RESET_OVR(1'h0), .RX_CDR_RESET(1'h0),
    .RX_PCS_RESET_OVR(1'h0), .RX_PCS_RESET(1'h0),
    .RX_BUF_RESET_OVR(1'h0), .RX_BUF_RESET(1'h0),
    .RX_POLARITY_OVR(1'h0), .RX_POLARITY(1'h0),
    .RX_8B10B_EN_OVR(1'h0), .RX_8B10B_EN(1'h0),
    .RX_8B10B_BYPASS(8'h0), .RX_BYTE_REALIGN(1'h0),
    .TX_SEL_PRE(5'h0), .TX_SEL_POST(5'h0), .TX_AMP(5'hF),
    .TX_BRANCH_EN_PRE(5'h0), .TX_BRANCH_EN_MAIN(6'h3F),
    .TX_BRANCH_EN_POST(5'h0), .TX_TAIL_CASCODE(3'h4),
    .TX_DC_ENABLE(7'h3F), .TX_DC_OFFSET(5'h8),
    .TX_CM_RAISE(5'h0), .TX_CM_THRESHOLD_0(5'hE),
    .TX_CM_THRESHOLD_1(5'h10),
    .TX_SEL_PRE_EI(5'h0), .TX_SEL_POST_EI(5'h0), .TX_AMP_EI(5'hF),
    .TX_BRANCH_EN_PRE_EI(5'h0), .TX_BRANCH_EN_MAIN_EI(6'h3F),
    .TX_BRANCH_EN_POST_EI(5'h0), .TX_TAIL_CASCODE_EI(3'h4),
    .TX_DC_ENABLE_EI(7'h3F), .TX_DC_OFFSET_EI(5'h0),
    .TX_CM_RAISE_EI(5'h0), .TX_CM_THRESHOLD_0_EI(5'hE),
    .TX_CM_THRESHOLD_1_EI(5'h10),
    .TX_SEL_PRE_RXDET(5'h0), .TX_SEL_POST_RXDET(5'h0),
    .TX_AMP_RXDET(5'hF), .TX_BRANCH_EN_PRE_RXDET(5'h0),
    .TX_BRANCH_EN_MAIN_RXDET(6'h3F), .TX_BRANCH_EN_POST_RXDET(5'h0),
    .TX_TAIL_CASCODE_RXDET(3'h4), .TX_DC_ENABLE_RXDET(7'h3F),
    .TX_DC_OFFSET_RXDET(5'h0), .TX_CM_RAISE_RXDET(5'h0),
    .TX_CM_THRESHOLD_0_RXDET(5'hE), .TX_CM_THRESHOLD_1_RXDET(5'h10),
    .TX_CALIB_EN(1'h0), .TX_CALIB_OVR(1'h0), .TX_CALIB_VAL(4'h0),
    .TX_CM_REG_KI(8'h80), .TX_CM_SAR_EN(1'h0), .TX_CM_REG_EN(1'h1),
    .TX_PMA_RESET_TIME(5'h3), .TX_PCS_RESET_TIME(5'h3),
    .TX_PCS_RESET_OVR(1'h0), .TX_PCS_RESET(1'h0),
    .TX_PMA_RESET_OVR(1'h0), .TX_PMA_RESET(1'h0),
    .TX_RESET_OVR(1'h0), .TX_RESET(1'h0),
    .TX_PMA_LOOPBACK(TX_PMA_LOOPBACK), .TX_PCS_LOOPBACK(1'h0),
    .TX_DATAPATH_SEL(DATAPATH_SEL), .TX_PRBS_OVR(1'h0),
    .TX_PRBS_SEL(3'b0), .TX_PRBS_FORCE_ERR(1'h0),
    .TX_LOOPBACK_OVR(1'h0), .TX_POWER_DOWN_OVR(1'h0),
    .TX_POWER_DOWN_N(1'h1), .TX_ELEC_IDLE_OVR(1'h0),
    .TX_ELEC_IDLE(1'h0), .TX_DETECT_RX_OVR(1'h0),
    .TX_DETECT_RX(1'h0), .TX_POLARITY_OVR(1'h0), .TX_POLARITY(1'h0),
    .TX_8B10B_EN_OVR(1'h0), .TX_8B10B_EN(1'h0),
    .TX_DATA_OVR(1'h0), .TX_DATA_CNT(3'h0), .TX_DATA_VALID(1'h0),
    .PLL_EN_ADPLL_CTRL(1'h1), .PLL_CONFIG_SEL(1'h1),
    .PLL_SET_OP_LOCK(1'h0), .PLL_ENFORCE_LOCK(1'h0),
    .PLL_DISABLE_LOCK(1'h0), .PLL_LOCK_WINDOW(1'h1),
    .PLL_FAST_LOCK(1'h1), .PLL_SYNC_BYPASS(1'h0),
    .PLL_PFD_SELECT(1'h0), .PLL_REF_BYPASS(1'h0),
    .PLL_REF_SEL(1'h1), .PLL_REF_RTERM(1'h1),
    .PLL_FCNTRL(PLL_FCNTRL), .PLL_MAIN_DIVSEL(PLL_MAIN_DIVSEL),
    .PLL_OUT_DIVSEL(PLL_OUT_DIVSEL),
    .PLL_CI(5'h3), .PLL_CP(10'h50), .PLL_AO(4'h0),
    .PLL_SCAP(3'h0), .PLL_FILTER_SHIFT(2'h2),
    .PLL_SAR_LIMIT(3'h2), .PLL_FT(11'h200),
    .PLL_OPEN_LOOP(1'h0), .PLL_SCAP_AUTO_CAL(1'h1),
    .PLL_BISC_MODE(3'h4), .PLL_BISC_TIMER_MAX(4'hF),
    .PLL_BISC_OPT_DET_IND(1'h0), .PLL_BISC_PFD_SEL(1'h0),
    .PLL_BISC_DLY_DIR(1'h0), .PLL_BISC_COR_DLY(3'h1),
    .PLL_BISC_CAL_SIGN(1'h0), .PLL_BISC_CAL_AUTO(1'h1),
    .PLL_BISC_CP_MIN(5'h4), .PLL_BISC_CP_MAX(5'h12),
    .PLL_BISC_CP_START(5'hC), .PLL_BISC_DLY_PFD_MON_REF(5'h0),
    .PLL_BISC_DLY_PFD_MON_DIV(5'h2),
    .SERDES_ENABLE(1'h1), .SERDES_AUTO_INIT(1'h0), .SERDES_TESTMODE(1'h0)
) i_cc_serdes (
    .RX_CLK_O(RX_CLK_O), .PLL_CLK_O(PLL_CLK_O),
    .LOOPBACK_I(3'b000),
    .TX_RESET_I(trx_rst_i), .RX_RESET_I(trx_rst_i),
    .RX_PMA_RESET_I(1'b0), .RX_EQA_RESET_I(1'b0),
    .RX_CDR_RESET_I(1'b0), .RX_PCS_RESET_I(1'b0),
    .RX_BUF_RESET_I(1'b0), .TX_PCS_RESET_I(1'b0),
    .TX_PMA_RESET_I(1'b0), .PLL_RESET_I(pll_rst_i),
    .TX_RESET_DONE_O(TX_RESET_DONE_O),
    .RX_RESET_DONE_O(RX_RESET_DONE_O),
    .TX_CLK_I(PLL_CLK_O),
    .TX_DATA_I(serdes_tx_data),
    .TX_POWER_DOWN_N_I(1'h1), .TX_POLARITY_I(1'h0),
    .TX_PRBS_SEL_I(serdes_prbs_sel),
    .TX_PRBS_FORCE_ERR_I(1'b0),
    .TX_8B10B_EN_I(serdes_8b10b_en),
    .TX_8B10B_BYPASS_I(8'h0),
    .TX_CHAR_IS_K_I(serdes_tx_k),
    .TX_CHAR_DISPMODE_I(8'h0), .TX_CHAR_DISPVAL_I(8'h0),
    .TX_ELEC_IDLE_I(serdes_elec_idle),
    .TX_DETECT_RX_I(1'b1),
    .TX_BUF_ERR_O(TX_BUF_ERR_O),
    .RX_CLK_I(RX_CLK_O),
    .RX_POWER_DOWN_N_I(1'h1), .RX_POLARITY_I(1'h0),
    .RX_PRBS_SEL_I(serdes_prbs_sel),
    .RX_PRBS_CNT_RESET_I(1'b0),
    .RX_PRBS_ERR_O(RX_PRBS_ERR_O),
    .RX_8B10B_EN_I(serdes_8b10b_en),
    .RX_8B10B_BYPASS_I(8'h0),
    .RX_EN_EI_DETECTOR_I(1'h0), .RX_COMMA_DETECT_EN_I(1'h1),
    .RX_SLIDE_I(1'h0), .RX_MCOMMA_ALIGN_I(1'h1), .RX_PCOMMA_ALIGN_I(1'h1),
    .RX_DATA_O(RX_DATA_O),
    .RX_NOT_IN_TABLE_O(RX_NOT_IN_TABLE_O),
    .RX_CHAR_IS_COMMA_O(rx_char_is_comma),
    .RX_CHAR_IS_K_O(rx_char_is_k), .RX_DISP_ERR_O(),
    .TX_DETECT_RX_DONE_O(TX_DETECT_RX_DONE_O),
    .TX_DETECT_RX_PRESENT_O(TX_DETECT_RX_PRESENT_O),
    .RX_BUF_ERR_O(RX_BUF_ERR_O),
    .RX_BYTE_IS_ALIGNED_O(), .RX_BYTE_REALIGN_O(), .RX_EI_EN_O(),
    .REGFILE_CLK_I(1'h0), .REGFILE_WE_I(1'h0), .REGFILE_EN_I(1'h0),
    .REGFILE_ADDR_I(8'h0), .REGFILE_DI_I(16'h0), .REGFILE_MASK_I(16'h0),
    .REGFILE_DO_O(REGFILE_DO_O), .REGFILE_RDY_O(REGFILE_RDY_O)
);

// ─── Status sync + LED ────────────────────────────────────────────────────────
reg tx_s0=0, tx_s1=0, rxd_s0=0, rxd_s1=0;
always @(posedge clk_fast) begin
    tx_s0<=TX_RESET_DONE_O; tx_s1<=tx_s0;
    rxd_s0<=RX_RESET_DONE_O; rxd_s1<=rxd_s0;
end
wire tx_rdy = tx_s1;
wire rx_rdy = rxd_s1;
wire serdes_rdy = tx_rdy && rx_rdy;

reg [25:0] cnt=0;
reg pass=0;
reg [26:0] report_timer=0;
reg        auto_report=0;
always @(posedge clk_fast) begin
    cnt  <= cnt + 1;
    pass <= (rx_char_is_comma != 8'h00);
    auto_report <= 0;
    if (report_timer == 27'd100_000_000) begin  // every 2 seconds
        report_timer <= 0;
        auto_report  <= 1;
    end else report_timer <= report_timer + 1;
end

assign led = !serdes_rdy ? 1'b1 :
              pass        ? cnt[22] :
                            cnt[24];

// ─── ROM ─────────────────────────────────────────────────────────────────────
reg [7:0] rom [0:219];
initial begin
    // 0: "Mode: COMMA\r\n"
    rom[0]="M";rom[1]="o";rom[2]="d";rom[3]="e";rom[4]=":";rom[5]=" ";
    rom[6]="C";rom[7]="O";rom[8]="M";rom[9]="M";rom[10]="A";
    rom[11]="\r";rom[12]="\n";rom[13]=NUL;
    // 20: "Mode: PRBS-7\r\n"
    rom[20]="M";rom[21]="o";rom[22]="d";rom[23]="e";rom[24]=":";rom[25]=" ";
    rom[26]="P";rom[27]="R";rom[28]="B";rom[29]="S";rom[30]="-";rom[31]="7";
    rom[32]="\r";rom[33]="\n";rom[34]=NUL;
    // 40: "Mode: COUNT\r\n"
    rom[40]="M";rom[41]="o";rom[42]="d";rom[43]="e";rom[44]=":";rom[45]=" ";
    rom[46]="C";rom[47]="O";rom[48]="U";rom[49]="N";rom[50]="T";
    rom[51]="\r";rom[52]="\n";rom[53]=NUL;
    // 60: "Mode: IDLE\r\n"
    rom[60]="M";rom[61]="o";rom[62]="d";rom[63]="e";rom[64]=":";rom[65]=" ";
    rom[66]="I";rom[67]="D";rom[68]="L";rom[69]="E";
    rom[70]="\r";rom[71]="\n";rom[72]=NUL;
    // 80: "SerDes: READY\r\n"
    rom[80]="S";rom[81]="e";rom[82]="r";rom[83]="D";rom[84]="e";rom[85]="s";
    rom[86]=":";rom[87]=" ";rom[88]="R";rom[89]="E";rom[90]="A";rom[91]="D";
    rom[92]="Y";rom[93]="\r";rom[94]="\n";rom[95]=NUL;
    // 100: "SerDes: NOT READY\r\n"
    rom[100]="S";rom[101]="e";rom[102]="r";rom[103]="D";rom[104]="e";
    rom[105]="s";rom[106]=":";rom[107]=" ";rom[108]="N";rom[109]="O";
    rom[110]="T";rom[111]=" ";rom[112]="R";rom[113]="E";rom[114]="A";
    rom[115]="D";rom[116]="Y";rom[117]="\r";rom[118]="\n";rom[119]=NUL;
    // 130: "Commands: COMMA PRBS COUNT IDLE STATUS HELP\r\n"
    rom[130]="C";rom[131]="o";rom[132]="m";rom[133]="m";rom[134]="a";
    rom[135]="n";rom[136]="d";rom[137]="s";rom[138]=":";rom[139]=" ";
    rom[140]="C";rom[141]="O";rom[142]="M";rom[143]="M";rom[144]="A";
    rom[145]=" ";rom[146]="P";rom[147]="R";rom[148]="B";rom[149]="S";
    rom[150]=" ";rom[151]="C";rom[152]="O";rom[153]="U";rom[154]="N";
    rom[155]="T";rom[156]=" ";rom[157]="I";rom[158]="D";rom[159]="L";
    rom[160]="E";rom[161]=" ";rom[162]="S";rom[163]="T";rom[164]="A";
    rom[165]="T";rom[166]="U";rom[167]="S";rom[168]=" ";rom[169]="H";
    rom[170]="E";rom[171]="L";rom[172]="P";rom[173]="\r";rom[174]="\n";
    rom[175]=NUL;
    // 180: "Unknown command\r\n"
    rom[180]="U";rom[181]="n";rom[182]="k";rom[183]="n";rom[184]="o";
    rom[185]="w";rom[186]="n";rom[187]=" ";rom[188]="c";rom[189]="o";
    rom[190]="m";rom[191]="m";rom[192]="a";rom[193]="n";rom[194]="d";
    rom[195]="\r";rom[196]="\n";rom[197]=NUL;
    // 200: "[OK] "
    rom[200]="[";rom[201]="O";rom[202]="K";rom[203]="]";rom[204]=" ";rom[205]=NUL;
    // 206: "[--] "
    rom[206]="[";rom[207]="-";rom[208]="-";rom[209]="]";rom[210]=" ";rom[211]=NUL;
    // 212: "[!!] "
    rom[212]="[";rom[213]="!";rom[214]="!";rom[215]="]";rom[216]=" ";rom[217]=NUL;
end

// ─── Parser ───────────────────────────────────────────────────────────────────
localparam PARSE_IDLE=2'd0, PARSE_EXEC=2'd1, PARSE_WAIT=2'd2;
reg [1:0] parse_state=PARSE_IDLE;
reg [7:0] resp_addr=0;
reg       resp_req=0;
reg       tx_busy=0;
reg       auto_phase=0;  // 0=print prefix, 1=print mode

always @(posedge clk_fast) begin
    cmd_done<=0; resp_req<=0;
    case (parse_state)
        PARSE_IDLE: begin
            if (cmd_ready) begin
                cmd_done<=1; auto_phase<=0;
                if      (is_comma)  begin tx_mode<=0; resp_addr<=0;   parse_state<=PARSE_EXEC; end
                else if (is_prbs)   begin tx_mode<=1; resp_addr<=20;  parse_state<=PARSE_EXEC; end
                else if (is_count)  begin tx_mode<=2; resp_addr<=40;  parse_state<=PARSE_EXEC; end
                else if (is_idle)   begin tx_mode<=3; resp_addr<=60;  parse_state<=PARSE_EXEC; end
                else if (is_status) begin resp_addr<=(serdes_rdy?8'd80:8'd100); parse_state<=PARSE_EXEC; end
                else if (is_help)   begin resp_addr<=130; parse_state<=PARSE_EXEC; end
                else                begin resp_addr<=180; parse_state<=PARSE_EXEC; end
            end else if (auto_report && !tx_busy) begin
                // periodic auto status: print prefix then mode
                auto_phase <= 1;
                if      (!serdes_rdy) resp_addr <= 212;  // [!!]
                else if (pass)        resp_addr <= 200;  // [OK]
                else                  resp_addr <= 206;  // [--]
                parse_state <= PARSE_EXEC;
            end
        end
        PARSE_EXEC: begin
            if (!tx_busy) begin resp_req<=1; parse_state<=PARSE_WAIT; end
        end
        PARSE_WAIT: begin
            resp_req<=0;
            if (!tx_busy && !resp_req) begin
                if (auto_phase) begin
                    // after prefix, print the current mode
                    auto_phase <= 0;
                    case (tx_mode)
                        0: resp_addr <= 0;
                        1: resp_addr <= 20;
                        2: resp_addr <= 40;
                        default: resp_addr <= 60;
                    endcase
                    parse_state <= PARSE_EXEC;
                end else parse_state <= PARSE_IDLE;
            end
        end
    endcase
end

// ─── UART TX ─────────────────────────────────────────────────────────────────
reg [9:0] bit_cnt=0;
reg [2:0] bit_idx=0;
reg [7:0] tx_shift=0;
reg [7:0] tx_addr=0;
reg [1:0] tx_rom_mode=0;
localparam TX_IDLE=3'd0,TX_LOAD=3'd1,TX_CHECK=3'd2,
           TX_START=3'd3,TX_DATA=3'd4,TX_STOP=3'd5;
reg [2:0] tx_state=TX_IDLE;

always @(posedge clk_fast) begin
    case (tx_state)
        TX_IDLE: begin
            tx<=1; tx_busy<=0;
            if (echo_req) begin
                tx_shift<=echo_byte; bit_cnt<=BIT_PERIOD-1; bit_idx<=0;
                tx_busy<=1; tx_rom_mode<=0; tx_state<=TX_START;
            end else if (resp_req) begin
                tx_addr<=resp_addr; tx_busy<=1; tx_rom_mode<=1; tx_state<=TX_LOAD;
            end
        end
        TX_LOAD:  begin tx_shift<=rom[tx_addr]; tx_state<=TX_CHECK; end
        TX_CHECK: begin
            if (tx_shift==NUL) begin tx_busy<=0; tx_state<=TX_IDLE; end
            else begin bit_cnt<=BIT_PERIOD-1; bit_idx<=0; tx_state<=TX_START; end
        end
        TX_START: begin
            tx<=0;
            if (bit_cnt==0) begin bit_cnt<=BIT_PERIOD-1; tx_state<=TX_DATA; end
            else bit_cnt<=bit_cnt-1;
        end
        TX_DATA: begin
            tx<=tx_shift[0];
            if (bit_cnt==0) begin
                tx_shift<=tx_shift>>1; bit_cnt<=BIT_PERIOD-1;
                if (bit_idx==7) tx_state<=TX_STOP; else bit_idx<=bit_idx+1;
            end else bit_cnt<=bit_cnt-1;
        end
        TX_STOP: begin
            tx<=1;
            if (bit_cnt==0) begin
                if (tx_rom_mode==1) begin tx_addr<=tx_addr+1; tx_state<=TX_LOAD; end
                else begin tx_busy<=0; tx_state<=TX_IDLE; end
            end else bit_cnt<=bit_cnt-1;
        end
    endcase
end

endmodule
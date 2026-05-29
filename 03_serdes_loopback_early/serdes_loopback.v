module serdes_loopback (
    input  wire clk,
    output reg  tx,
    output reg  led
);

wire clk_fast;
CC_PLL #(
    .REF_CLK("10.0"), .OUT_CLK("50.0"),
    .PERF_MD("SPEED"),
    .LOCK_REQ(1), .CLK270_DOUB(0), .CLK180_DOUB(0)
) pll_fabric (
    .CLK_REF(clk), .CLK_FEEDBACK(1'b0), .USR_CLK_REF(1'b0),
    .USR_LOCKED_STDY_RST(1'b0), .USR_PLL_LOCKED_STDY(), .USR_PLL_LOCKED(),
    .CLK270(), .CLK180(), .CLK90(), .CLK0(clk_fast), .CLK_REF_OUT()
);

// ─── SerDes clocks ────────────────────────────────────────────────────────────
wire serdes_pll_clk;  // TX datapath clock from SerDes ADPLL
wire serdes_rx_clk;   // RX datapath clock from CDR

// ─── SerDes status ────────────────────────────────────────────────────────────
wire [63:0] rx_data;
wire tx_reset_done, rx_reset_done;

// Synchronise SerDes status into clk_fast domain
reg tx_done_s0=0, tx_done_s1=0;
reg rx_done_s0=0, rx_done_s1=0;
always @(posedge clk_fast) begin
    tx_done_s0 <= tx_reset_done; tx_done_s1 <= tx_done_s0;
    rx_done_s0 <= rx_reset_done; rx_done_s1 <= rx_done_s0;
end
wire tx_rdy = tx_done_s1;
wire rx_rdy = rx_done_s1;

// ─── Power-on reset for SerDes ────────────────────────────────────────────────
reg [10:0] por_cnt = 0;
reg        serdes_rst = 1;
always @(posedge clk_fast) begin
    if (!por_cnt[10]) begin
        por_cnt    <= por_cnt + 1;
        serdes_rst <= 1;
    end else begin
        serdes_rst <= 0;
    end
end

// ADPLL settings — 80-bit datapath, same as reference
parameter N1     = 1;
parameter N2     = 2;
parameter N3     = 3;
parameter OUTDIV = 4;
parameter DATAPATH = 80;

parameter [1:0] DATAPATH_SEL = 2'b11; // 80/64 bit
parameter [5:0] PLL_FCNTRL   = 6'h3A;
parameter [5:0] PLL_MAIN_DIVSEL = 6'h1B;
parameter [1:0] PLL_OUT_DIVSEL  = 2'b11;

CC_SERDES #(
    // ── RX reset timing ──────────────────────────────────────────────────────
    .RX_BUF_RESET_TIME(5'h3),
    .RX_PCS_RESET_TIME(5'h3),
    .RX_RESET_TIMER_PRESC(5'h0),
    .RX_RESET_DONE_GATE(1'h0),
    .RX_CDR_RESET_TIME(5'h3),
    .RX_EQA_RESET_TIME(5'h3),
    .RX_PMA_RESET_TIME(5'h3),
    .RX_WAIT_CDR_LOCK(1'b0),
    .RX_CALIB_EN(1'h0), .RX_CALIB_OVR(1'h0), .RX_CALIB_VAL(4'h0),
    .RX_RTERM_VCMSEL(3'h4), .RX_RTERM_PD(1'h0),
    // ── RX equaliser ─────────────────────────────────────────────────────────
    .RX_EQA_CKP_LF(8'hA3), .RX_EQA_CKP_HF(8'hA3),
    .RX_EQA_CKP_OFFSET(8'h01), .RX_EN_EQA(1'h0),
    .RX_EQA_LOCK_CFG(4'h0), .RX_TH_MON1(5'h8),
    .RX_EN_EQA_EXT_VALUE(4'h0), .RX_TH_MON2(5'h8),
    .RX_TAPW(5'h8), .RX_AFE_OFFSET(5'h8),
    .RX_EQA_CONFIG(16'h1C0), .RX_AFE_PEAK(5'hF),
    .RX_AFE_GAIN(4'h8), .RX_AFE_VCMSEL(3'h4),
    // ── RX CDR ───────────────────────────────────────────────────────────────
    .RX_CDR_CKP(8'hF8), .RX_CDR_CKI(8'h00),
    .RX_CDR_TRANS_TH(9'h80), .RX_CDR_LOCK_CFG(6'hB),
    .RX_CDR_FREQ_ACC(15'h0), .RX_CDR_PHASE_ACC(16'h0),
    .RX_CDR_SET_ACC_CONFIG(2'h0), .RX_CDR_FORCE_LOCK(1'h0),
    // ── RX comma alignment ───────────────────────────────────────────────────
    .RX_ALIGN_MCOMMA_VALUE(10'h283), .RX_MCOMMA_ALIGN_OVR(1'h0),
    .RX_MCOMMA_ALIGN(1'h0),
    .RX_ALIGN_PCOMMA_VALUE(10'h17C), .RX_PCOMMA_ALIGN_OVR(1'h0),
    .RX_PCOMMA_ALIGN(1'h0),
    .RX_ALIGN_COMMA_WORD(2'h3), .RX_ALIGN_COMMA_ENABLE(10'h3FF),
    .RX_SLIDE_MODE(2'b00), .RX_COMMA_DETECT_EN_OVR(1'h0),
    .RX_COMMA_DETECT_EN(1'h0), .RX_SLIDE(2'h0),
    // ── RX misc ──────────────────────────────────────────────────────────────
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
    .RX_POWER_DOWN_N(1'h1), .RX_RESET_OVR(1'h0), .RX_RESET(1'h0),
    .RX_PMA_RESET_OVR(1'h0), .RX_PMA_RESET(1'h0),
    .RX_EQA_RESET_OVR(1'h0), .RX_EQA_RESET(1'h0),
    .RX_CDR_RESET_OVR(1'h0), .RX_CDR_RESET(1'h0),
    .RX_PCS_RESET_OVR(1'h0), .RX_PCS_RESET(1'h0),
    .RX_BUF_RESET_OVR(1'h0), .RX_BUF_RESET(1'h0),
    .RX_POLARITY_OVR(1'h0), .RX_POLARITY(1'h0),
    .RX_8B10B_EN_OVR(1'h0), .RX_8B10B_EN(1'h0),
    .RX_8B10B_BYPASS(8'h0), .RX_BYTE_REALIGN(1'h0),
    // ── TX driver ────────────────────────────────────────────────────────────
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
    .TX_PMA_LOOPBACK(2'b01),   // ← loopback from TX driver
    .TX_PCS_LOOPBACK(1'h0),
    .TX_DATAPATH_SEL(DATAPATH_SEL), .TX_PRBS_OVR(1'h0),
    .TX_PRBS_SEL(3'b0), .TX_PRBS_FORCE_ERR(1'h0),
    .TX_LOOPBACK_OVR(1'h0), .TX_POWER_DOWN_OVR(1'h0),
    .TX_POWER_DOWN_N(1'h1), .TX_ELEC_IDLE_OVR(1'h0),
    .TX_ELEC_IDLE(1'h0), .TX_DETECT_RX_OVR(1'h0),
    .TX_DETECT_RX(1'h0), .TX_POLARITY_OVR(1'h0), .TX_POLARITY(1'h0),
    .TX_8B10B_EN_OVR(1'h0), .TX_8B10B_EN(1'h0),
    .TX_DATA_OVR(1'h0), .TX_DATA_CNT(3'h0), .TX_DATA_VALID(1'h0),
    // ── ADPLL ────────────────────────────────────────────────────────────────
    .PLL_EN_ADPLL_CTRL(1'h1),
    .PLL_CONFIG_SEL(1'h1),
    .PLL_SET_OP_LOCK(1'h0), .PLL_ENFORCE_LOCK(1'h0),
    .PLL_DISABLE_LOCK(1'h0), .PLL_LOCK_WINDOW(1'h1),
    .PLL_FAST_LOCK(1'h1), .PLL_SYNC_BYPASS(1'h0),
    .PLL_PFD_SELECT(1'h0), .PLL_REF_BYPASS(1'h0),
    .PLL_REF_SEL(1'h1),      // LVDS reference clock
    .PLL_REF_RTERM(1'h1),
    .PLL_FCNTRL(PLL_FCNTRL),
    .PLL_MAIN_DIVSEL(PLL_MAIN_DIVSEL),
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
    // ── SERDES enable ────────────────────────────────────────────────────────
    .SERDES_ENABLE(1'h1),
    .SERDES_AUTO_INIT(1'h0),   // ← manual init via parameters
    .SERDES_TESTMODE(1'h0)
) serdes_inst (
    .PLL_CLK_O      (serdes_pll_clk),
    .RX_CLK_O       (serdes_rx_clk),
    .LOOPBACK_I     (3'b000),
    .TX_RESET_I     (serdes_rst), .RX_RESET_I(serdes_rst),
    .RX_PMA_RESET_I (1'b0), .RX_EQA_RESET_I(1'b0),
    .RX_CDR_RESET_I (1'b0), .RX_PCS_RESET_I(1'b0),
    .RX_BUF_RESET_I (1'b0), .TX_PCS_RESET_I(1'b0),
    .TX_PMA_RESET_I (1'b0), .PLL_RESET_I(serdes_rst),
    .TX_RESET_DONE_O(tx_reset_done),
    .RX_RESET_DONE_O(rx_reset_done),
    .TX_CLK_I       (clk_fast),   // TX uses ADPLL output
    .TX_DATA_I      (64'hBCBCBCBCBCBCBCBC),
    .TX_POWER_DOWN_N_I(1'b1),
    .TX_POLARITY_I  (1'b0),
    .TX_PRBS_SEL_I  (3'b0), .TX_PRBS_FORCE_ERR_I(1'b0),
    .TX_8B10B_EN_I  (1'b1),
    .TX_8B10B_BYPASS_I(8'h0),
    .TX_CHAR_IS_K_I (8'hFF),
    .TX_CHAR_DISPMODE_I(8'h0), .TX_CHAR_DISPVAL_I(8'h0),
    .TX_ELEC_IDLE_I (1'b0), .TX_DETECT_RX_I(1'b1),
    .RX_CLK_I       (serdes_rx_clk),    // RX uses CDR clock
    .RX_POWER_DOWN_N_I(1'b1),
    .RX_POLARITY_I  (1'b0),
    .RX_PRBS_SEL_I  (3'b0), .RX_PRBS_CNT_RESET_I(1'b0),
    .RX_8B10B_EN_I  (1'b1), .RX_8B10B_BYPASS_I(8'h0),
    .RX_EN_EI_DETECTOR_I(1'b0), .RX_COMMA_DETECT_EN_I(1'b1),
    .RX_SLIDE_I     (1'b0),
    .RX_MCOMMA_ALIGN_I(1'b1), .RX_PCOMMA_ALIGN_I(1'b1),
    .RX_DATA_O      (rx_data),
    .RX_NOT_IN_TABLE_O(), .RX_CHAR_IS_COMMA_O(),
    .RX_CHAR_IS_K_O(), .RX_DISP_ERR_O(),
    .TX_DETECT_RX_DONE_O(), .TX_DETECT_RX_PRESENT_O(),
    .TX_BUF_ERR_O(), .RX_PRBS_ERR_O(), .RX_BUF_ERR_O(),
    .RX_BYTE_IS_ALIGNED_O(), .RX_BYTE_REALIGN_O(),
    .RX_EI_EN_O(),
    .REGFILE_CLK_I(1'b0), .REGFILE_WE_I(1'b0), .REGFILE_EN_I(1'b0),
    .REGFILE_ADDR_I(8'h0), .REGFILE_DI_I(16'h0), .REGFILE_MASK_I(16'h0),
    .REGFILE_DO_O(), .REGFILE_RDY_O()
);

// ─── Status and LED ───────────────────────────────────────────────────────────
reg [25:0] cnt = 0;
reg pass = 0;

always @(posedge clk_fast) begin
    cnt  <= cnt + 1;
    pass <= (rx_data == 64'hBCBCBCBCBCBCBCBC);
    if (!tx_rdy || !rx_rdy)

        led <= 1;           // off: not ready
    else if (pass)
        led <= cnt[22];     // fast blink: loopback pass
    else
        led <= cnt[24];     // slow blink: aligned but mismatch
end

// ─── UART TX status ───────────────────────────────────────────────────────────
localparam BIT_PERIOD = 50_000_000 / 57600;
reg [9:0]  bit_cnt   = 0;
reg [3:0]  bit_idx   = 0;
reg [7:0]  tx_shift  = 0;
reg [25:0] report_cnt = 0;
reg        tx_busy   = 0;

always @(posedge clk_fast) begin
    if (!tx_busy) begin
        tx <= 1;
        report_cnt <= report_cnt + 1;
        if (report_cnt == 0) begin
            if (!tx_rdy || !rx_rdy) tx_shift <= "R";
            else if (pass)                         tx_shift <= "P";
            else                                   tx_shift <= "F";
            tx_busy <= 1; bit_cnt <= BIT_PERIOD-1; bit_idx <= 0;
        end
    end else begin
        if (bit_cnt == 0) begin
            bit_cnt <= BIT_PERIOD-1;
            case (bit_idx)
                0: begin tx <= 0; bit_idx <= 1; end
                1,2,3,4,5,6,7,8: begin tx <= tx_shift[bit_idx-1]; bit_idx <= bit_idx+1; end
                default: begin tx <= 1; tx_busy <= 0; bit_idx <= 0; end
            endcase
        end else bit_cnt <= bit_cnt - 1;
    end
end

endmodule
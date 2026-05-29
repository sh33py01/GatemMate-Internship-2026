module uart_tx_test (
    input  wire clk,
    input  wire rx,
    output reg  tx,
    output reg  led
);

parameter  CLK_FREQ  = 10_000_000;
parameter  BAUD_RATE = 57600;

localparam integer BIT_PERIOD  = CLK_FREQ / BAUD_RATE;  // 173
localparam integer HALF_PERIOD = BIT_PERIOD / 2;         // 86

// ─── 3-stage synchroniser ──────────────────────────────────────────────────
reg rx_s0 = 1, rx_s1 = 1, rx_s2 = 1;
wire rx_sync = rx_s2;

always @(posedge clk) begin
    rx_s0 <= rx;
    rx_s1 <= rx_s0;
    rx_s2 <= rx_s1;
end

// ─── RX ────────────────────────────────────────────────────────────────────
localparam RX_IDLE  = 2'd0,
           RX_START = 2'd1,
           RX_DATA  = 2'd2,
           RX_STOP  = 2'd3;

reg [1:0]  rx_state   = RX_IDLE;
reg [7:0]  rx_cnt     = 0;
reg [2:0]  rx_bit_idx = 0;
reg [7:0]  rx_shift   = 0;
reg        rx_valid   = 0;
reg [7:0]  rx_byte    = 0;

always @(posedge clk) begin
    rx_valid <= 0;  // default pulse low every cycle

    case (rx_state)
        RX_IDLE: begin
            if (rx_sync == 0) begin
                rx_state <= RX_START;
                rx_cnt   <= HALF_PERIOD - 1;
            end
        end

        RX_START: begin
            if (rx_cnt == 0) begin
                if (rx_sync == 0) begin
                    rx_state   <= RX_DATA;
                    rx_cnt     <= BIT_PERIOD - 1;
                    rx_bit_idx <= 0;
                end else begin
                    rx_state <= RX_IDLE;  // glitch rejection
                end
            end else begin
                rx_cnt <= rx_cnt - 1;
            end
        end

        RX_DATA: begin
            if (rx_cnt == 0) begin
                rx_shift   <= {rx_sync, rx_shift[7:1]};
                rx_cnt     <= BIT_PERIOD - 1;
                if (rx_bit_idx == 7) begin
                    rx_state <= RX_STOP;
                end else begin
                    rx_bit_idx <= rx_bit_idx + 1;
                end
            end else begin
                rx_cnt <= rx_cnt - 1;
            end
        end

        RX_STOP: begin
            if (rx_cnt == 0) begin
                rx_state <= RX_IDLE;
                if (rx_sync == 1) begin  // valid stop bit
                    rx_byte  <= rx_shift;
                    rx_valid <= 1;
                end
            end else begin
                rx_cnt <= rx_cnt - 1;
            end
        end
    endcase
end

// ─── TX ────────────────────────────────────────────────────────────────────
localparam TX_IDLE  = 2'd0,
           TX_START = 2'd1,
           TX_DATA  = 2'd2,
           TX_STOP  = 2'd3;

reg [1:0]  tx_state   = TX_IDLE;
reg [7:0]  tx_cnt     = 0;
reg [2:0]  tx_bit_idx = 0;
reg [7:0]  tx_shift   = 0;

always @(posedge clk) begin
    case (tx_state)
        TX_IDLE: begin
            tx <= 1;
            if (rx_valid) begin
                tx_shift   <= rx_byte;
                tx_cnt     <= BIT_PERIOD - 1;
                tx_bit_idx <= 0;
                tx_state   <= TX_START;
            end
        end

        TX_START: begin
            tx <= 0;
            if (tx_cnt == 0) begin
                tx_cnt   <= BIT_PERIOD - 1;
                tx_state <= TX_DATA;    // fixed: was "state" before
            end else begin
                tx_cnt <= tx_cnt - 1;
            end
        end

        TX_DATA: begin
            tx <= tx_shift[0];
            if (tx_cnt == 0) begin
                tx_shift <= tx_shift >> 1;
                tx_cnt   <= BIT_PERIOD - 1;
                if (tx_bit_idx == 7) begin
                    tx_state <= TX_STOP;
                end else begin
                    tx_bit_idx <= tx_bit_idx + 1;
                end
            end else begin
                tx_cnt <= tx_cnt - 1;
            end
        end

        TX_STOP: begin
            tx <= 1;
            if (tx_cnt == 0) begin
                tx_state <= TX_IDLE;
            end else begin
                tx_cnt <= tx_cnt - 1;
            end
        end
    endcase
end

// ─── LED: active LOW ───────────────────────────────────────────────────────
localparam LED_TICKS = CLK_FREQ / 5;  // 0.2s — long enough to see clearly
reg [20:0] led_cnt = 0;

always @(posedge clk) begin
    if (rx_valid) begin
        led     <= 0;               // on
        led_cnt <= LED_TICKS - 1;
    end else if (led_cnt != 0) begin
        led_cnt <= led_cnt - 1;
    end else begin
        led <= 1;                   // off
    end
end

endmodule

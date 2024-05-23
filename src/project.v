/*
 * Copyright (c) 2024 Ciro Cattuto <ciro.cattuto@gmail.com>
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_ccattuto_conway (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

// -------------- I/O PINS ---------------------------

// All output pins must be assigned. If not used, assign to 0.
assign uio_out = 0;
assign uio_oe  = 0;
assign uo_out[3:0] = 0;
assign uo_out[7:5] = 0;

// UART signals
wire uart_rx, uart_tx;
assign uart_rx = ui_in[3];
assign uo_out[4] = uart_tx;

// clock
localparam CLOCK_FREQ = 24000000;

// reset
wire boot_reset;
assign boot_reset = ~rst_n;


// -------------- UART TRANSMITTER ---------------------------

wire uart_tx_en;
assign uart_tx_en = 1;

reg [7:0]   uart_tx_data;
reg         uart_tx_valid;
wire        uart_tx_ready;

UARTTransmitter #(
    .CLOCK_RATE(CLOCK_FREQ),
    .BAUD_RATE(115200)
) uart_tx_inst (
    .clk(clk),
    .reset(boot_reset),       // reset
    .enable(uart_tx_en),      // TX enable
    .valid(uart_tx_valid),    // start of TX
    .in(uart_tx_data),        // data to transmit
    .out(uart_tx),            // TX signal
    .ready(uart_tx_ready)     // read for TX data
);


// -------------- UART RECEIVER ---------------------------

wire uart_rx_en;
assign uart_rx_en = 1;

wire [7:0]  uart_rx_data;
wire        uart_rx_valid;
wire        uart_rx_error;
wire        uart_rx_overrun;
reg         uart_rx_ready;

UARTReceiver #(
    .CLOCK_RATE(CLOCK_FREQ),
    .BAUD_RATE(115200)
) uart_rx_inst (
    .clk(clk),
    .reset(boot_reset),       // reset
    .enable(uart_rx_en),      // RX enable
    .in(uart_rx),             // RX signal
    .ready(uart_rx_ready),    // ready to consume RX data
    .out(uart_rx_data),       // RX wires
    .valid(uart_rx_valid),    // RX completed
    .error(uart_rx_error),    // RX error
    .overrun(uart_rx_overrun) // RX overrun
);


// -------------- RNG ---------------------------

wire rng;

lfsr_rng lfsr(
  .clk(clk),
  .reset(boot_reset),
  .random_bit(rng)
);


// ----------------- SIMULATION PARAMS -------------------------

localparam logWIDTH = 3, logHEIGHT = 3;         // 8x8 board
localparam UPDATE_INTERVAL = CLOCK_FREQ / 5;    // 5 Hz simulation update

localparam WIDTH = 2 ** logWIDTH;
localparam HEIGHT = 2 ** logHEIGHT;
localparam BOARD_SIZE = WIDTH * HEIGHT;

reg board_state [0:BOARD_SIZE-1];         // current state of the simulation
reg board_state_next [0:BOARD_SIZE-1];    // next state of the simulation


// ----------------- SIMULATION CONTROL VIA UART RX --------------------

localparam ACTION_IDLE = 0, ACTION_UPDATE = 1, ACTION_COPY = 2, ACTION_DISPLAY = 3, ACTION_RND = 4, ACTION_INIT = 5;
reg [2:0] action;
reg action_init_complete, action_update_complete, action_copy_complete, action_display_complete;

reg running;  // high when simulation is advancing automatically based on timer
reg [31:0] timer;

always @(posedge clk) begin
  if (boot_reset) begin
    action <= ACTION_INIT;
    running <= 0;
    timer <= 0;
    uart_rx_ready <= 0;
  end else begin
    case (action)
      // at init, any received character triggers randomized initialization and refresh over UART
      ACTION_INIT: begin
        if (!(uart_rx_valid & uart_rx_ready)) begin
          uart_rx_ready <= 1;
        end else begin
          action <= ACTION_RND;
          uart_rx_ready <= 0;
        end
      end

      // idle loop: simulation controlled via characters received over UART 
      ACTION_IDLE: begin
        if (uart_rx_valid & uart_rx_ready) begin
          uart_rx_ready <= 0;
          
          case (uart_rx_data)
            // '0' randomizes the state of the simulation
            48: begin
              action <= ACTION_RND;
            end

            // '1' advances the simulation by 1 step
            49: begin
              if (~running) begin
                action <= ACTION_UPDATE;
              end else begin
                running <= 0;
                timer <= 0;
              end
            end

            // ' ' toggles simulation timer-based advancing
            32: begin
              running <= ~running;
              timer <= 0;
            end

            default: begin
              action <= ACTION_IDLE;
            end
          endcase
        end else if (uart_rx_valid) begin
          uart_rx_ready <= 1;
        end else if (running) begin // timer-based update trigger
          if (timer < UPDATE_INTERVAL) begin
            timer <= timer + 1;
          end else begin
            timer <= 0;
            uart_rx_ready <= 0;
            action <= ACTION_UPDATE;
          end
        end
      end

      // STATE TRANSITION LOGIC
      //
      // - ACTION_UPDATE computes board_state_next based on board_state
      // - ACTION_COPY copies board_state_next over board_state
      // - ACTION_DISPLAY prints out board_state over UART (ANSI terminal)
      // - ACTION_RND randomizes board_state

      // DISPLAY -> IDLE
      ACTION_DISPLAY: begin
        if (action_display_complete) begin
          action <= ACTION_IDLE;
        end
      end

      // COPY -> DISPLAY (-> IDLE)
      ACTION_COPY: begin
        if (action_copy_complete)
          action <= ACTION_DISPLAY;
      end

      // UPDATE -> COPY (-> DISPLAY -> IDLE)
      ACTION_UPDATE: begin
        if (action_update_complete)
          action <= ACTION_COPY;
      end

      // RND -> DISPLAY
      ACTION_RND: begin
        if (action_init_complete)
          action <= ACTION_DISPLAY;
      end

      default: begin
        action <= ACTION_IDLE;
      end
    endcase
  end
end


// ----------------- ACTION: RANDOMIZE SIMULATION STATE --------------------

reg [logWIDTH+logHEIGHT-1:0] index2;

always @(posedge clk) begin
  if (boot_reset) begin
    action_init_complete <= 0;
    index2 <= 0;
  end else if (action == ACTION_RND && !action_init_complete) begin
    board_state[index2] <= rng;
    if (index2 < BOARD_SIZE - 1) begin
      index2 <= index2 + 1;
    end else  begin
      index2 <= 0;
      action_init_complete <= 1;
    end
  end else begin
    action_init_complete <= 0;
  end
end


// ----------------- ACTION: COMPUTE SIMULATION'S NEXT STATE --------------------

reg [logWIDTH+logHEIGHT-1:0] index3;    // index of cell being updated
wire [logWIDTH-1:0] cell_x;             // x-coordinate (column) of cell being updated
wire [logHEIGHT-1:0] cell_y;            // y coordinate (row) of cell being updated
assign cell_x = index3[logWIDTH-1:0];
assign cell_y = index3[logWIDTH+logHEIGHT-1:logWIDTH];

reg [3:0] neigh_index;                  // index of neighboring cell (0 to 7)
reg [3:0] num_neighbors;                // number of neighbors of current cell

localparam HEIGHT_MASK = {logHEIGHT{1'b1}};
localparam WIDTH_MASK = {logWIDTH{1'b1}};

always @(posedge clk) begin
  if (boot_reset) begin
    action_update_complete <= 0;
    index3 <= 0;
    neigh_index <= 0;
    num_neighbors <= 0;
  end else if (action == ACTION_UPDATE && !action_update_complete) begin
    // loop over the 8 neighbors of the current cell
    case (neigh_index)
      0: begin // (-1, +1)
        num_neighbors <= num_neighbors + board_state[((cell_y + 1) & HEIGHT_MASK) << logWIDTH | ((cell_x - 1) & WIDTH_MASK)];
        neigh_index <= neigh_index + 1;
      end

      1: begin // (0, +1)
        num_neighbors <= num_neighbors + board_state[((cell_y + 1) & HEIGHT_MASK) << logWIDTH | ((cell_x + 0) & WIDTH_MASK)];
        neigh_index <= neigh_index + 1; 
      end

      2: begin // (+1, +1)
        num_neighbors <= num_neighbors + board_state[((cell_y + 1) & HEIGHT_MASK) << logWIDTH | ((cell_x + 1) & WIDTH_MASK)];
        neigh_index <= neigh_index + 1;
      end

      3: begin // (-1, 0)
        num_neighbors <= num_neighbors + board_state[((cell_y + 0) & HEIGHT_MASK) << logWIDTH | ((cell_x - 1) & WIDTH_MASK)];
        neigh_index <= neigh_index + 1;
      end

      4: begin // (+1, 0)
        num_neighbors <= num_neighbors + board_state[((cell_y + 0) & HEIGHT_MASK) << logWIDTH | ((cell_x + 1) & WIDTH_MASK)];
        neigh_index <= neigh_index + 1;
      end

      5: begin // (-1, -1)
        num_neighbors <= num_neighbors + board_state[((cell_y - 1) & HEIGHT_MASK) << logWIDTH | ((cell_x - 1) & WIDTH_MASK)];
        neigh_index <= neigh_index + 1;
      end

      6: begin // (0, -1)
        num_neighbors <= num_neighbors + board_state[((cell_y - 1) & HEIGHT_MASK) << logWIDTH | ((cell_x + 0) & WIDTH_MASK)];
        neigh_index <= neigh_index + 1;
      end

      7: begin // (+1, -1)
        num_neighbors <= num_neighbors + board_state[((cell_y - 1) & HEIGHT_MASK) << logWIDTH | ((cell_x + 1) & WIDTH_MASK)];
        neigh_index <= neigh_index + 1;
      end

      // this state (neigh_index = 8) is used to compute the new state of the current cell
      // according to the rules of Conway's Game of Life
      8: begin
        board_state_next[index3] <= (board_state[index3] && (num_neighbors == 2)) | (num_neighbors == 3);

        neigh_index <= 0;
        num_neighbors <= 0;

        // advance to next cell to be updated, or terminate
        if (index3 < BOARD_SIZE - 1) begin
          index3 <= index3 + 1;
        end else begin
          index3 <= 0;
          action_update_complete <= 1;
        end
      end

      default: begin
        neigh_index <= 0;
      end
    endcase
  end else begin
    action_update_complete <= 0;
  end 
end


// --------------- ACTION: COPY NEW SIMULATION STATE OVER OLD ONE --------------------

reg [logWIDTH+logHEIGHT-1:0] index4;

always @(posedge clk) begin
  if (boot_reset) begin
    action_copy_complete <= 0;
    index4 <= 0;
  end else if (action == ACTION_COPY && !action_copy_complete) begin
    board_state[index4] <= board_state_next[index4];
    if (index4 < BOARD_SIZE - 1) begin
      index4 <= index4 + 1;
    end else begin
      index4 <= 0;
      action_copy_complete <= 1;
    end
  end else begin
    action_copy_complete <= 0;
  end
end


// --------------- ACTION: DISPLAY SIMULATION STATE OVER UART --------------------

localparam TX_IDLE = 0, TX_SEND = 1, TX_WAIT = 2, TX_SEND_CRLF = 3, TX_WAIT_CRLF = 4, TX_SEND_HOME = 5, TX_WAIT_HOME = 6, TX_INIT = 7, TX_WAIT_INIT = 8;
reg [3:0] txstate;
reg [logWIDTH+logHEIGHT-1:0] index;   // current cell index
reg [logWIDTH:0] colindex;            // column index of current cell
reg [5:0] txindex;                    // index into strings to be printed (welcome message, formatting)

localparam CELL_ALIVE_CHAR = 79;      // "O" is used to display alive cells
localparam CELL_DEAD_CHAR = 32;       // " " is used to display dead cells

always @(posedge clk) begin
  if (boot_reset) begin
    uart_tx_data <= 0;
    uart_tx_valid <= 0;
    index <= 0;
    colindex <= 0;
    txindex <= 0;
    action_display_complete <= 0;
    txstate <= TX_INIT;
  end else if (action == ACTION_DISPLAY && !action_display_complete) begin
        case (txstate)
          TX_IDLE: begin
            uart_tx_valid <= 0;
            index <= 0;
            colindex <= 0;
            txindex <= 0;
            if (action_display_complete == 0) begin
              txstate <= TX_SEND_HOME;
            end
          end

          // Sends ASCII character corresponding to current cell state,
          // then waits (TX_WAIT) for UART transmitted to be ready
          // and advances to the next cell.
          TX_SEND: begin
            if (colindex < WIDTH) begin
              uart_tx_data <= board_state[index] ? CELL_ALIVE_CHAR : CELL_DEAD_CHAR; // cell state to ASCII char
              index <= index + 1;
              colindex <= colindex + 1;
              txstate <= TX_WAIT;
            end else begin
              colindex <= 0;
              txstate <= TX_SEND_CRLF;
            end
          end

          TX_WAIT: begin
            if (uart_tx_ready && !uart_tx_valid ) begin
              uart_tx_valid <= 1;
            end else if (uart_tx_valid && !uart_tx_ready) begin
              uart_tx_valid <= 0;
              if (index != 0) begin
                txstate <= TX_SEND;
              end else begin
                txstate <= TX_IDLE;      
                action_display_complete <= 1;
              end
            end
          end        

          // Sends CR+LF (used at the end of every row)
          TX_SEND_CRLF: begin
            if (txindex < 2) begin
              uart_tx_data <= (txindex == 0) ? 13 : 10;
              txindex <= txindex + 1;
              txstate <= TX_WAIT_CRLF;
            end else begin
              txindex <= 0;
              txstate <= TX_SEND;              
            end
          end

          TX_WAIT_CRLF: begin
            if (uart_tx_ready && !uart_tx_valid ) begin
              uart_tx_valid <= 1;
            end else if (uart_tx_valid && !uart_tx_ready) begin
              uart_tx_valid <= 0;
              txstate <= TX_SEND_CRLF;
            end
          end        

          // Sends ANSI "home" escape sequence [0x1b, '[', ';', 'H']
          // moving the cursor to the top left of the terminal (0,0) 
          TX_SEND_HOME: begin
            if (txindex < 4) begin
              case (txindex)
                0: begin
                  uart_tx_data <= 27;
                end
                1: begin
                  uart_tx_data <= 91;
                end
                2: begin
                  uart_tx_data <= 59;
                end
                3: begin
                  uart_tx_data <= 72;
                end
                default:
                  uart_tx_data <= 0;
              endcase
              txindex <= txindex + 1;
              txstate <= TX_WAIT_HOME;
            end else begin
              txindex <= 0;
              txstate <= TX_SEND;
            end
          end

          TX_WAIT_HOME: begin
            if (uart_tx_ready && !uart_tx_valid ) begin
              uart_tx_valid <= 1;
            end else if (uart_tx_valid && !uart_tx_ready) begin
              uart_tx_valid <= 0;
              txstate <= TX_SEND_HOME;
            end
          end

          // prints out welcome message and usage instructions stored in string_init (ROM below)
          TX_INIT: begin
            if (txindex < STRING_INIT_LEN) begin
              uart_tx_data <= string_init[txindex];
              txindex <= txindex + 1;
              txstate <= TX_WAIT_INIT;    
            end else begin
              txstate <= TX_IDLE;
              action_display_complete <= 1;    
            end
          end

          TX_WAIT_INIT: begin
            if (uart_tx_ready && !uart_tx_valid ) begin
              uart_tx_valid <= 1;
            end else if (uart_tx_valid && !uart_tx_ready) begin
              uart_tx_valid <= 0;
              txstate <= TX_INIT;
            end
          end

          default: begin
            txstate <= TX_IDLE;
          end
        endcase
  end else begin
    action_display_complete <= 0;
  end
end

// ROM containing the welcome message with usage instructions
localparam STRING_INIT_LEN = 57;
reg [7:0] string_init [0:STRING_INIT_LEN-1];
initial begin
  $readmemh("string_init.hex", string_init);
end

endmodule

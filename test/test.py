# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: MIT

import cocotb
from cocotb.clock import Clock
import cocotb.result
from cocotb.triggers import Timer, Edge, with_timeout


@cocotb.test(timeout_time=20, timeout_unit='ms')
async def test(dut):
    dut._log.info("Start")

    # Set the clock period to 24 MHz
    clock = Clock(dut.clk, 41666, units="ps")
    cocotb.start_soon(clock.start())

    # UART signals
    uart_rx = dut.ui_in[3]
    uart_tx = dut.uo_out[4]

    # GPIO config
    do_gpio_config(dut)

    # reset
    await do_reset(dut)
    assert uart_tx == 1

    # send CR over UART to trigger init message
    f = cocotb.start_soon(send_cmd(dut, uart_rx, 13))
    init_str = await get_uart_str(dut, uart_tx)
    await f
    #dut._log.info("Received: %s" % init_str)
    assert init_str == INIT_STRING
    dut._log.info("Received correct init string")

    await Timer(0.7, units="ms")
    f = cocotb.start_soon(send_cmd(dut, uart_rx, ord('0')))
    board_state = await get_uart_str(dut, uart_tx)
    await f

    dut._log.info(board_state)




# HELPER FUNCTIONS

async def send_cmd(dut, uart_rx, cmd=13):
    dut._log.info("Sending: 0x%02X" % cmd)
    await do_tx(uart_rx, 115200, cmd)

async def do_reset(dut):
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.rst_n.value = 0
    await Timer(1, units="us")
    dut.rst_n.value = 1
    await Timer(5, units="us")

def do_gpio_config(dut):
    dut._log.info("GPIO config")
    # GPIO IN
    dut.ui_in.value = 0
    # set RX high
    dut.ui_in[3].value = 1

    # GPIO IN/OUT
    dut.uio_in.value = 0

async def do_tx(uart_rx, baud, data):
    # prepare random test data
    TEST_BITS_LSB = [(data >> s) & 1 for s in range(8)]

    # send start bit (0), 8 data bits, stop bit (1)
    for tx_bit in [0] + TEST_BITS_LSB + [1]:
        uart_rx.value = tx_bit
        await Timer(int(1.0 / baud * 1e12), units="ps")

async def do_rx(dut, uart_tx, baud, timeout_us=0):
    if timeout_us > 0:
        count = 0
        while uart_tx.value == 1 and count < timeout_us:
            did_timeout = False
            count += 1
            try:
                await with_timeout(Edge(dut.uo_out), 1, 'us')
            except cocotb.result.SimTimeoutError:
                did_timeout = True

        if did_timeout:
            return None
    else:
        while uart_tx.value == 1:
            await Edge(dut.uo_out)
    
    assert uart_tx.value == 0

    # wait 1/2 bit
    await Timer(int(0.5 / baud * 1e12), units="ps")
    # check start bit
    assert uart_tx.value == 0

    # 8 data bits
    data = 0
    for i in range(8):
        await Timer(int(1.0 / baud * 1e12), units="ps")
        data |= (1 << i) if uart_tx.value == 1 else 0

    # check stop bit
    await Timer(int(1.0 / baud * 1e12), units="ps")
    assert uart_tx.value == 1

    return data

async def get_uart_str(dut, uart_tx):
    blist = []

    while True:
        rx_byte = await do_rx(dut, uart_tx, 115200, timeout_us=100)
        if rx_byte == None:
            break
        dut._log.info("Received 0x%02X" % rx_byte)
        blist.append(rx_byte)

    return bytes(blist).decode()

INIT_STRING = "\x1bc" + "\x1b[92m" + "Hello!\r\nspace: start/stop\r\n0: randomize\r\n1: step\r\n"


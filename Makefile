# Verification and synthesis helpers. Needs Python 3.9+, Icarus Verilog and (for `synth`) Yosys.

PY ?= python3

.PHONY: test sim waves synth equations clean

test:            ## model checks + RTL simulations of every variant (pytest)
	$(PY) -m pytest -v

sim:             ## RTL simulations only, with a PASS/FAIL line per design/variant
	cd python && $(PY) sim.py

waves:           ## VCD dumps in build/ and docs/images/parallel_waveform.svg
	cd python && $(PY) sim.py --waves && $(PY) wave_svg.py

synth:           ## Yosys synthesis for Xilinx 7-series, prints resource usage
	for d in parallel serial; do \
	  yosys -q -p "read_verilog rtl/crc32_$$d.v; synth_xilinx -family xc7 -top crc32_$$d -flatten; tee -o /dev/stdout stat"; \
	done

equations:       ## regenerate the parallel next-state XOR equations
	cd python && $(PY) crc32_model.py --equations

clean:
	rm -rf build .pytest_cache python/__pycache__

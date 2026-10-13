CA65   := $(HOME)/.local/bin/ca65
LD65   := $(HOME)/.local/bin/ld65

all: build/ash.xex build/boot.bin

build/ash.xex: ash.s kernel.s fileops.s editor.s ash.cfg
	@mkdir -p build
	$(CA65) -g -l build/ash.lst -o build/ash.o ash.s
	$(LD65) -C ash.cfg -Ln build/ash.lbl -m build/ash.map -o $@ build/ash.o
	@ls -l $@

build/boot.bin: boot.s boot.cfg
	@mkdir -p build
	$(CA65) -o build/boot.o boot.s
	$(LD65) -C boot.cfg -o $@ build/boot.o

# release/ASH.ATR (bootable, SD, with ASH.XEX + README.TXT) and release/ASH.XEX
release: all
	cp build/ash.xex release/ASH.XEX
	python3 tools/mkatr.py -o release/ASH.ATR --shell build/ash.xex --boot build/boot.bin \
	    release/ASH.XEX release/README.TXT
	python3 tools/mkatr.py --fsck release/ASH.ATR

clean:
	rm -rf build

.PHONY: all clean release

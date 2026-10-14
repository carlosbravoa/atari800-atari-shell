CA65   := $(HOME)/.local/bin/ca65
LD65   := $(HOME)/.local/bin/ld65

all: build/ash.xex build/boot.bin

# ASH-TN: the Tang Nano 20K build (PC-link mailbox, pc/getw commands)
tn: build/ash-tn.xex build/boot.bin

# ASH.CAR: ASH-TN in a Williams 32K cartridge (bank 0 = cart.s, banks 1-2 = the image)
cart: build/ASH.CAR

build/ash-cart.xex: ash.s kernel.s fileops.s editor.s tn.s ash-cart.cfg
	@mkdir -p build
	$(CA65) -g -D TN=1 -D CART=1 -l build/ash-cart.lst -o build/ash-cart.o ash.s
	$(LD65) -C ash-cart.cfg -Ln build/ash-cart.lbl -m build/ash-cart.map -o $@ build/ash-cart.o

build/cart0.bin: cart.s cart.cfg
	@mkdir -p build
	$(CA65) -o build/cart0.o cart.s
	$(LD65) -C cart.cfg -o $@ build/cart0.o

build/ASH.CAR: build/ash-cart.xex build/cart0.bin tools/mkcar.py
	python3 tools/mkcar.py -o $@ build/cart0.bin build/ash-cart.xex

build/ash-tn.xex: ash.s kernel.s fileops.s editor.s tn.s ash.cfg
	@mkdir -p build
	$(CA65) -g -D TN=1 -l build/ash-tn.lst -o build/ash-tn.o ash.s
	$(LD65) -C ash.cfg -Ln build/ash-tn.lbl -m build/ash-tn.map -o $@ build/ash-tn.o
	@ls -l $@

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
release: all tn
	cp build/ash.xex release/ASH.XEX
	cp build/ash-tn.xex release/ASH-TN.XEX
	python3 tools/mkatr.py -o release/ASH.ATR --shell build/ash.xex --boot build/boot.bin \
	    release/ASH.XEX release/README.TXT
	python3 tools/mkatr.py -o release/ASH-TN.ATR --shell build/ash-tn.xex --boot build/boot.bin \
	    release/ASH-TN.XEX release/README.TXT
	python3 tools/mkatr.py --fsck release/ASH.ATR
	python3 tools/mkatr.py --fsck release/ASH-TN.ATR

clean:
	rm -rf build

.PHONY: all tn cart clean release

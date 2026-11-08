# ZLMod — Makefile (pure clang, no Theos)
# Usage: make            → build/libZLMod.dylib (arm64, min iOS 15.1)
#        make gates      → static verification of the artifact
#        make clean

ARCH      := arm64
PLATFORM  := iphoneos
MIN_IOS   := 15.1
SRC_DIR   := Sources
BUILD_DIR := build
TARGET    := $(BUILD_DIR)/libZLMod.dylib
COMPAT_MANIFEST := Resources/compatibility.json
COMPAT_GENERATOR := Scripts/generate_compatibility.py
COMPAT_HEADER := Sources/ZLModCompatibilityData.h

SDKROOT := $(shell xcrun --sdk $(PLATFORM) --show-sdk-path)

SOURCES := $(wildcard $(SRC_DIR)/*.m)

CFLAGS := -arch $(ARCH) \
          -isysroot $(SDKROOT) \
          -miphoneos-version-min=$(MIN_IOS) \
          -fobjc-arc -fmodules -fblocks \
          -O2 -Wall -Wextra -Wno-unused-parameter \
          -install_name @rpath/libZLMod.dylib

FRAMEWORKS := -framework UIKit -framework Foundation -framework QuartzCore -framework Security

all: $(TARGET)

$(COMPAT_HEADER): $(COMPAT_MANIFEST) $(COMPAT_GENERATOR)
	python3 $(COMPAT_GENERATOR) $(COMPAT_MANIFEST) $(COMPAT_HEADER)

$(TARGET): $(SOURCES) $(SRC_DIR)/ZLMod.h $(COMPAT_HEADER)
	@mkdir -p $(BUILD_DIR)
	xcrun --sdk $(PLATFORM) clang -dynamiclib $(CFLAGS) $(FRAMEWORKS) -o $(TARGET) $(SOURCES)
	xcrun codesign --force --sign - --timestamp=none $(TARGET)
	@echo "built $(TARGET)"

gates: $(TARGET)
	./Scripts/gates.sh

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all gates clean

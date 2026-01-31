# Makefile for rme-adi2-ctl
#
# Build requirements: libasound2-dev (Debian/Ubuntu) or alsa-lib-devel (Fedora)

CC ?= gcc
CFLAGS ?= -Wall -Wextra -O2
LDFLAGS ?=

# ALSA flags via pkg-config
ALSA_CFLAGS := $(shell pkg-config --cflags alsa 2>/dev/null)
ALSA_LIBS := $(shell pkg-config --libs alsa 2>/dev/null)

ifeq ($(ALSA_LIBS),)
$(error ALSA development libraries not found. Install libasound2-dev)
endif

CFLAGS += $(ALSA_CFLAGS)
LDFLAGS += $(ALSA_LIBS)

TARGET = rme-adi2-ctl
PREFIX ?= /usr/local

.PHONY: all clean install uninstall

all: $(TARGET)

$(TARGET): rme-adi2-ctl.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(TARGET)

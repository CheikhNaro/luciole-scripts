CC ?= gcc
CXX ?= g++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra
CFLAGS ?= -O2 -Wall -Wextra
PKG_CONFIG ?= pkg-config

PKGS = wayland-client cairo pangocairo xkbcommon
CXXFLAGS_ALL = $(CXXFLAGS) $(shell $(PKG_CONFIG) --cflags $(PKGS))
LIBS_ALL = $(shell $(PKG_CONFIG) --libs $(PKGS)) -lm

TARGET = luciole-dialog

all: $(TARGET)

xdg-shell-protocol.o: xdg-shell-protocol.c xdg-shell-client-protocol.h
	$(CC) $(CFLAGS) $(shell $(PKG_CONFIG) --cflags wayland-client) -c xdg-shell-protocol.c -o xdg-shell-protocol.o

main.o: main.cpp xdg-shell-client-protocol.h
	$(CXX) $(CXXFLAGS_ALL) -c main.cpp -o main.o

$(TARGET): main.o xdg-shell-protocol.o
	$(CXX) main.o xdg-shell-protocol.o -o $(TARGET) $(LIBS_ALL)

clean:
	rm -f $(TARGET) *.o

.PHONY: all clean

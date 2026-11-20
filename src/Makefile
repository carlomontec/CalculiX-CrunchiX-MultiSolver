
CFLAGS = -Wall -O2 -g -I ../../spooles -DARCH="Linux" -DSPOOLES -DARPACK -DMATRIXSTORAGE -DUSE_MT=1
FFLAGS = -Wall -O2 -g -cpp -fopenmp -Wno-unused-dummy-argument -Wno-unused-variable -Wno-unused-label

CC=clang
FC=gfortran

.c.o :
	$(CC) $(CFLAGS) -c $<
.f.o :
	$(FC) $(FFLAGS) -c $<

include Makefile.inc

SCCXMAIN = CalculiX.c

OCCXF = $(SCCXF:.f=.o)
OCCXC = $(SCCXC:.c=.o)
OCCXMAIN = $(SCCXMAIN:.c=.o)

DIR=../../spooles

SDKROOT = $(shell xcrun --show-sdk-path)
ARPACK_LIBS = $(shell pkg-config --libs arpack)

LIBS = \
       $(DIR)/spooles.a \
       $(ARPACK_LIBS) \
       -Wl,-syslibroot,$(SDKROOT) \
       -framework Accelerate

CalculiX: $(OCCXMAIN) CalculiX.a
	$(FC) $(FFLAGS) -o $@ $(OCCXMAIN) CalculiX.a $(LIBS)

CalculiX.a: $(OCCXF) $(OCCXC) buildinfo.o
	ar vr $@ $?

# buildinfo.c contains the compile time. It is not part of SCCXC, since it
# has to be recompiled whenever any other object file changes

buildinfo.o: $(OCCXMAIN) $(OCCXF) $(OCCXC)

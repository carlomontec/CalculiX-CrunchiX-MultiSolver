# Standalone Makefile for CalculiX CCX with MUMPS 5.x Solver
# Supports both workspace-local MUMPS and system-wide installation

CFLAGS = -Wall -O2 -fopenmp -DMUMPS -DARCH="Linux" -I. -I.. -I/usr/include/mumps_seq -I/usr/include -I../../mumps/include -I../../mumps/include/mumps_seq
FFLAGS = -Wall -O2 -fopenmp -cpp -fallow-argument-mismatch

CC = gcc
FC = gfortran

-include Makefile.inc

SCCXMAIN = CalculiX.c

OCCXF = $(SCCXF:.f=.o)
OCCXC = $(SCCXC:.c=.o)
OCCXMAIN = $(SCCXMAIN:.c=.o)

DIR = ../../mumps/lib

LIBS = \
	$(DIR)/libdmumps.a \
	$(DIR)/libmumps_common.a \
	$(DIR)/libpord.a \
	$(DIR)/libmpiseq.a \
	-larpack -llapack -lblas -lpthread -lm -ldl

CalculiX: $(OCCXMAIN) $(OCCXC) $(OCCXF)
	$(FC) -fopenmp -Wall -O2 -o $@ $(OCCXMAIN) $(OCCXC) $(OCCXF) $(LIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.f
	$(FC) $(FFLAGS) -c $< -o $@

clean:
	rm -f *.o CalculiX

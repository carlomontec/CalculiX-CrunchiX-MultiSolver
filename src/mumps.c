/*     CALCULIX - A 3-dimensional finite element program                 */
/*              Copyright (C) 1998 Guido Dhondt                          */
/*     This program is free software; you can redistribute it and/or     */
/*     modify it under the terms of the GNU General Public License as    */
/*     published by the Free Software Foundation; either version 2 of    */
/*     the License, or (at your option) any later version.               */

/*     This program is distributed in the hope that it will be useful,   */
/*     but WITHOUT ANY WARRANTY; without even the implied warranty of    */ 
/*     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the      */
/*     GNU General Public License for more details.                      */

/*     You should have received a copy of the GNU General Public License */
/*     along with this program; if not, write to the Free Software       */
/*     Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.         */

#ifdef MUMPS

#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include "CalculiX.h"
#include "mumps.h"
#include <dmumps_c.h>

static DMUMPS_STRUC_C id;
static ITG mumps_initialized = 0;

void mumps_factor(double *ad, double *au, double *adb, double *aub,
                  double *sigma, ITG *icol, ITG *irow,
                  ITG *neq, ITG *nzs, ITG *symmetryflag, ITG *inputformat,
                  ITG *jq, ITG *nzs3){

  ITG i, j, k, l;
  ITG nnz;
  char *env;
  ITG nthread = 1;

  if(*symmetryflag == 0){
    printf(" Factoring the system of equations using the symmetric MUMPS solver\n");
  }else{
    printf(" Factoring the system of equations using the unsymmetric MUMPS solver\n");
  }

  /* 1. Initialize MUMPS instance */
  if(!mumps_initialized){
    id.comm_fortran = -987654; /* USE_COMM_WORLD (single host / sequential MPI) */
    id.par = 1;                /* Host participates in computation */
    id.sym = (*symmetryflag == 0) ? 2 : 0; /* 2 = symmetric general, 0 = unsymmetric */
    id.job = -1;               /* JOB = -1: Initialize MUMPS */
    dmumps_c(&id);
    mumps_initialized = 1;
  }

  /* 2. Determine thread count from environment */
  env = getenv("CCX_NPROC_EQUATION_SOLVER");
  if(env){
    nthread = atoi(env);
  }else{
    env = getenv("OMP_NUM_THREADS");
    if(env){ nthread = atoi(env); }
  }
  if(nthread < 1) nthread = 1;
  printf(" number of threads = %d\n\n", (int)nthread);

  /* 3. Configure MUMPS control parameters (Fortran index - 1 in C) */
  id.icntl[0] = -1;  /* ICNTL(1): Error output stream suppressed (quiet) */
  id.icntl[1] = -1;  /* ICNTL(2): Diagnostic output stream suppressed */
  id.icntl[2] = -1;  /* ICNTL(3): Global info output stream suppressed */
  id.icntl[3] = 0;   /* ICNTL(4): Printing level (0 = quiet) */
  id.icntl[5] = 7;   /* ICNTL(6): Automatic permutation strategy for structural matrices */
  id.icntl[7] = 77;  /* ICNTL(8): Automatic matrix scaling */
  id.icntl[15] = (MUMPS_INT)nthread; /* ICNTL(16): OpenMP thread count */

  /* 4. Optional Block Low-Rank (BLR) compression for memory reduction */
  if(getenv("CCX_MUMPS_BLR")){
    id.icntl[34] = 1;    /* ICNTL(35): Enable BLR compression */
    id.icntl[35] = 0;    /* ICNTL(36): BLR variant (0 = default) */
    id.cntl[1]   = 1e-7; /* CNTL(2): BLR dropping threshold */
    printf(" MUMPS Block Low-Rank (BLR) compression enabled (epsilon = 1e-7)\n");
  }

  id.n = *neq;

  /* 5. Sparse matrix coordinate format (COO) assembly */
  if(*symmetryflag == 0){
    /* Symmetric matrix: Lower triangular part */
    nnz = *neq + *nzs;
    id.nz = nnz;
    NNEW(id.irn, MUMPS_INT, nnz);
    NNEW(id.jcn, MUMPS_INT, nnz);
    NNEW(id.a, double, nnz);

    k = 0;
    l = 0;
    for(i = 0; i < *neq; i++){
      for(j = 0; j < icol[i]; j++){
        id.irn[k] = (MUMPS_INT)irow[l];
        id.jcn[k] = (MUMPS_INT)(i + 1);
        id.a[k]   = (*sigma == 0.) ? au[l] : (au[l] - (*sigma)*aub[l]);
        k++;
        l++;
      }
      /* Diagonal element */
      id.irn[k] = (MUMPS_INT)(i + 1);
      id.jcn[k] = (MUMPS_INT)(i + 1);
      id.a[k]   = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
      k++;
    }
  }else{
    /* Unsymmetric matrix */
    if(*inputformat == 3){
      nnz = *neq + *nzs;
      id.nz = nnz;
      NNEW(id.irn, MUMPS_INT, nnz);
      NNEW(id.jcn, MUMPS_INT, nnz);
      NNEW(id.a, double, nnz);

      k = 0;
      ITG k2 = 0;
      for(i = 0; i < *neq; i++){
        for(j = 0; j < icol[i]; j++){
          if(au[k] > 1.e-12 || au[k] < -1.e-12){
            id.jcn[k2] = (MUMPS_INT)(i + 1);
            id.irn[k2] = (MUMPS_INT)irow[k];
            id.a[k2]   = (*sigma == 0.) ? au[k] : (au[k] - (*sigma)*aub[k]);
            k2++;
          }
          k++;
        }
      }
      for(i = 0; i < *neq; i++){
        id.jcn[k2] = (MUMPS_INT)(i + 1);
        id.irn[k2] = (MUMPS_INT)(i + 1);
        id.a[k2]   = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
        k2++;
      }
      id.nz = k2;
    }else if(*inputformat == 1){
      nnz = *neq + 2*(*nzs);
      id.nz = nnz;
      NNEW(id.irn, MUMPS_INT, nnz);
      NNEW(id.jcn, MUMPS_INT, nnz);
      NNEW(id.a, double, nnz);

      k = 0;
      ITG idx = 0;
      for(i = 0; i < *neq; i++){
        for(j = 0; j < icol[i]; j++){
          id.irn[idx] = (MUMPS_INT)irow[k];
          id.jcn[idx] = (MUMPS_INT)(i + 1);
          id.a[idx]   = (*sigma == 0.) ? au[k] : (au[k] - (*sigma)*aub[k]);
          idx++;
          k++;
        }
      }
      for(i = 0; i < *neq; i++){
        for(j = jq[i]-1; j < jq[i+1]-1; j++){
          id.irn[idx] = (MUMPS_INT)(i + 1);
          id.jcn[idx] = (MUMPS_INT)irow[j];
          id.a[idx]   = (*sigma == 0.) ? au[j+*nzs3] : (au[j+*nzs3] - (*sigma)*aub[j+*nzs3]);
          idx++;
        }
      }
      for(i = 0; i < *neq; i++){
        id.irn[idx] = (MUMPS_INT)(i + 1);
        id.jcn[idx] = (MUMPS_INT)(i + 1);
        id.a[idx]   = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
        idx++;
      }
    }
  }

  /* 6. Execute Symbolic Analysis (JOB = 1) */
  id.job = 1;
  dmumps_c(&id);
  if(id.infog[0] < 0){
    printf(" *ERROR in MUMPS analysis phase: INFOG(1) = %d\n", (int)id.infog[0]);
    exit(1);
  }

  /* 7. Execute Numerical Factorization (JOB = 2) */
  id.job = 2;
  dmumps_c(&id);
  if(id.infog[0] < 0){
    printf(" *ERROR in MUMPS factorization phase: INFOG(1) = %d\n", (int)id.infog[0]);
    exit(1);
  }
}

void mumps_solve(double *b, ITG *neq, ITG *symmetryflag, ITG *inputformat, ITG *nrhs){
  id.rhs  = b;
  id.nrhs = (MUMPS_INT)(*nrhs);
  id.lrhs = (MUMPS_INT)(*neq);
  id.job  = 3; /* Solve / Forward-Backward substitution */
  dmumps_c(&id);
  if(id.infog[0] < 0){
    printf(" *ERROR in MUMPS solve phase: INFOG(1) = %d\n", (int)id.infog[0]);
    exit(1);
  }
}

void mumps_cleanup(ITG *neq, ITG *symmetryflag, ITG *inputformat){
  if(mumps_initialized){
    id.job = -2; /* End / Release all internal MUMPS memory */
    dmumps_c(&id);
    mumps_initialized = 0;
  }
  if(id.irn){ SFREE(id.irn); id.irn = NULL; }
  if(id.jcn){ SFREE(id.jcn); id.jcn = NULL; }
  if(id.a)  { SFREE(id.a);   id.a = NULL; }
}

void mumps_main(double *ad, double *au, double *adb, double *aub,
                double *sigma, double *b, ITG *icol, ITG *irow,
                ITG *neq, ITG *nzs, ITG *symmetryflag, ITG *inputformat,
                ITG *jq, ITG *nzs3, ITG *nrhs){

  if(*neq == 0) return;

  mumps_factor(ad, au, adb, aub, sigma, icol, irow, neq, nzs,
               symmetryflag, inputformat, jq, nzs3);

  mumps_solve(b, neq, symmetryflag, inputformat, nrhs);

  mumps_cleanup(neq, symmetryflag, inputformat);
}

#endif

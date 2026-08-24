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

/*
 * MUMPS 5.x Interface for CalculiX CCX
 * 
 * Note on Linux Linking:
 * On Debian/Ubuntu systems, link with 'libmumps-seq-dev' (sequential/OpenMP)
 * rather than 'libmumps-dev' (MPI). The sequential package bundles the 'mpiseq'
 * stub library, enabling multi-threaded OpenMP execution without requiring MPI_Init.
 */

static DMUMPS_STRUC_C id;
static ITG mumps_initialized = 0;
static ITG mumps_analyzed = 0;
static ITG mumps_prev_neq = 0;
static ITG mumps_prev_nnz = 0;
static ITG mumps_prev_sym = -1;

void mumps_cleanup(ITG *neq, ITG *symmetryflag, ITG *inputformat){
  if(mumps_initialized){
    id.job = -2; /* End / Release all internal MUMPS memory */
    dmumps_c(&id);
    mumps_initialized = 0;
    mumps_analyzed = 0;
    mumps_prev_neq = 0;
    mumps_prev_nnz = 0;
    mumps_prev_sym = -1;
  }
  if(id.irn){ SFREE(id.irn); id.irn = NULL; }
  if(id.jcn){ SFREE(id.jcn); id.jcn = NULL; }
  if(id.a)  { SFREE(id.a);   id.a = NULL; }
}

void mumps_factor(double *ad, double *au, double *adb, double *aub,
                  double *sigma, ITG *icol, ITG *irow,
                  ITG *neq, ITG *nzs, ITG *symmetryflag, ITG *inputformat,
                  ITG *jq, ITG *nzs3){

  ITG i, j, k, l;
  ITG nnz = 0;
  char *env;
  ITG nthread = 1;
  ITG target_sym = (*symmetryflag == 0) ? 2 : 0;

  if(*neq == 0) return;

  /* If symmetry type or dimensions changed, reset MUMPS instance */
  if(mumps_initialized && (mumps_prev_sym != target_sym || mumps_prev_neq != *neq)){
    mumps_cleanup(neq, symmetryflag, inputformat);
  }

  if(*symmetryflag == 0){
    printf(" Factoring the system of equations using the symmetric MUMPS solver\n");
  }else{
    printf(" Factoring the system of equations using the unsymmetric MUMPS solver\n");
  }

  /* 1. Initialize MUMPS instance if not active */
  if(!mumps_initialized){
    id.comm_fortran = -987654; /* USE_COMM_WORLD (sequential MPI stub) */
    id.par = 1;                /* Host participates in computation */
    id.sym = target_sym;       /* 2 = symmetric general, 0 = unsymmetric */
    id.job = -1;               /* Initialize MUMPS */
    dmumps_c(&id);
    mumps_initialized = 1;
    mumps_analyzed = 0;
    mumps_prev_sym = target_sym;
    mumps_prev_neq = *neq;

    /* 2. Configure thread count */
    env = getenv("CCX_NPROC_EQUATION_SOLVER");
    if(env){
      nthread = atoi(env);
    }else{
      env = getenv("OMP_NUM_THREADS");
      if(env){ nthread = atoi(env); }
    }
    if(nthread < 1) nthread = 1;

    /* 3. Configure MUMPS control parameters */
    id.icntl[0] = -1;  /* Error output stream suppressed (quiet) */
    id.icntl[1] = -1;  /* Diagnostic output stream suppressed */
    id.icntl[2] = -1;  /* Global info output stream suppressed */
    id.icntl[3] = 0;   /* Printing level (0 = quiet) */
    
    id.icntl[5] = getenv("CCX_MUMPS_ICNTL6") ? atoi(getenv("CCX_MUMPS_ICNTL6")) : 7;
    id.icntl[6] = getenv("CCX_MUMPS_ICNTL7") ? atoi(getenv("CCX_MUMPS_ICNTL7")) : 7;
    id.icntl[7] = getenv("CCX_MUMPS_ICNTL8") ? atoi(getenv("CCX_MUMPS_ICNTL8")) : 77;
    id.icntl[13] = 80; /* ICNTL(14): 80% memory increase for dynamic pivoting */
    id.icntl[15] = getenv("CCX_MUMPS_ICNTL16") ? atoi(getenv("CCX_MUMPS_ICNTL16")) : (MUMPS_INT)nthread;
    id.icntl[23] = 1;  /* ICNTL(24): Detect null pivots for contact/MPC constraints */
    id.cntl[0]   = 0.01; /* CNTL(1): Numerical pivoting threshold */
    
    if (getenv("CCX_MUMPS_ICNTL13")) id.icntl[12] = atoi(getenv("CCX_MUMPS_ICNTL13"));
    if (getenv("CCX_MUMPS_ICNTL48")) id.icntl[47] = atoi(getenv("CCX_MUMPS_ICNTL48"));

    if(getenv("CCX_MUMPS_BLR")){
      id.icntl[34] = 1;    /* Enable BLR compression */
      id.icntl[35] = 0;    /* BLR variant */
      id.cntl[1]   = 1e-7; /* BLR threshold */
    }
  }

  id.n = (MUMPS_INT)(*neq);

  /* 3. Configure MUMPS control parameters (Fortran index - 1 in C) */
  id.icntl[0] = -1;  /* ICNTL(1): Error output stream suppressed (quiet) */
  id.icntl[1] = -1;  /* ICNTL(2): Diagnostic output stream suppressed */
  id.icntl[2] = -1;  /* ICNTL(3): Global info output stream suppressed */
  id.icntl[3] = 0;   /* ICNTL(4): Printing level (0 = quiet) */
  
  /* Column permutation (ICNTL(6)): Must be 0 for symmetric matrices to preserve symmetry */
  id.icntl[5] = getenv("CCX_MUMPS_ICNTL6") ? atoi(getenv("CCX_MUMPS_ICNTL6")) : (*symmetryflag == 0 ? 0 : 7);
  id.icntl[6] = getenv("CCX_MUMPS_ICNTL7") ? atoi(getenv("CCX_MUMPS_ICNTL7")) : 7;
  /* Disable automatic scaling by default (0) to avoid numerical drift on reduced diagonal contact DOFs */
  id.icntl[7] = getenv("CCX_MUMPS_ICNTL8") ? atoi(getenv("CCX_MUMPS_ICNTL8")) : 0;
  id.icntl[15] = getenv("CCX_MUMPS_ICNTL16") ? atoi(getenv("CCX_MUMPS_ICNTL16")) : (MUMPS_INT)nthread;
  /* Enable null pivot detection (ICNTL(24) = 1) */
  id.icntl[23] = 1;
  
  if (getenv("CCX_MUMPS_ICNTL13")) id.icntl[12] = atoi(getenv("CCX_MUMPS_ICNTL13"));
  if (getenv("CCX_MUMPS_ICNTL48")) id.icntl[47] = atoi(getenv("CCX_MUMPS_ICNTL48"));

  /* Pivoting threshold: For symmetric indefinite matrices (SYM=2), default CNTL(1) is 0.0 */
  if(*symmetryflag == 0){
    id.cntl[0] = getenv("CCX_MUMPS_CNTL1") ? atof(getenv("CCX_MUMPS_CNTL1")) : 0.0;
  }

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
    nnz = *neq + *nzs;
    if(id.irn == NULL || mumps_prev_nnz != nnz){
      if(id.irn) SFREE(id.irn);
      if(id.jcn) SFREE(id.jcn);
      if(id.a)   SFREE(id.a);
      NNEW(id.irn, MUMPS_INT, nnz);
      NNEW(id.jcn, MUMPS_INT, nnz);
      NNEW(id.a, double, nnz);
      mumps_prev_nnz = nnz;
      mumps_analyzed = 0;
    }
    id.nz = (MUMPS_INT)nnz;

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
    if(*inputformat == 3){
      nnz = *neq + *nzs;
      if(id.irn == NULL || mumps_prev_nnz != nnz){
        if(id.irn) SFREE(id.irn);
        if(id.jcn) SFREE(id.jcn);
        if(id.a)   SFREE(id.a);
        NNEW(id.irn, MUMPS_INT, nnz);
        NNEW(id.jcn, MUMPS_INT, nnz);
        NNEW(id.a, double, nnz);
        mumps_prev_nnz = nnz;
        mumps_analyzed = 0;
      }
      id.nz = (MUMPS_INT)nnz;

      k = 0;
      ITG k2 = 0;
      for(i = 0; i < *neq; i++){
        for(j = 0; j < icol[i]; j++){
          id.irn[k2] = (MUMPS_INT)irow[k];
          id.jcn[k2] = (MUMPS_INT)(i + 1);
          id.a[k2]   = (*sigma == 0.) ? au[k] : (au[k] - (*sigma)*aub[k]);
          k2++;
          k++;
        }
      }
      for(i = 0; i < *neq; i++){
        id.irn[k2] = (MUMPS_INT)(i + 1);
        id.jcn[k2] = (MUMPS_INT)(i + 1);
        id.a[k2]   = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
        k2++;
      }
      id.nz = (MUMPS_INT)k2;
    }else{
      nnz = *neq + 2*(*nzs);
      if(id.irn == NULL || mumps_prev_nnz != nnz){
        if(id.irn) SFREE(id.irn);
        if(id.jcn) SFREE(id.jcn);
        if(id.a)   SFREE(id.a);
        NNEW(id.irn, MUMPS_INT, nnz);
        NNEW(id.jcn, MUMPS_INT, nnz);
        NNEW(id.a, double, nnz);
        mumps_prev_nnz = nnz;
        mumps_analyzed = 0;
      }
      id.nz = (MUMPS_INT)nnz;

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

  /* 5. Symbolic Analysis (JOB = 1) - only needed on first call or when sparsity changes */
  if(!mumps_analyzed){
    id.job = 1;
    dmumps_c(&id);
    if(id.infog[0] < 0){
      printf(" *ERROR in MUMPS analysis phase: INFOG(1) = %d\n", (int)id.infog[0]);
      exit(1);
    }
    mumps_analyzed = 1;
  }

  /* 6. Numerical Factorization (JOB = 2) */
  id.job = 2;
  dmumps_c(&id);
  if(id.infog[0] < 0){
    printf(" *ERROR in MUMPS factorization phase: INFOG(1) = %d\n", (int)id.infog[0]);
    exit(1);
  }
}

void mumps_solve(double *b, ITG *neq, ITG *symmetryflag, ITG *inputformat, ITG *nrhs){
  id.rhs  = b;
  id.nrhs = (MUMPS_INT)abs(*nrhs);
  id.lrhs = (MUMPS_INT)(*neq);

  /* Handle Adjoint Transpose Solve for Sensitivity Analysis (A^T x = b vs A x = b) */
  if (*nrhs < 0) {
    id.icntl[8] = 0; /* ICNTL(9) = 0: solve A^T x = b */
  } else {
    id.icntl[8] = 1; /* ICNTL(9) = 1: solve A x = b */
  }

  id.job  = 3; /* Solve / Forward-Backward substitution */
  dmumps_c(&id);
  if(id.infog[0] < 0){
    printf(" *ERROR in MUMPS solve phase: INFOG(1) = %d\n", (int)id.infog[0]);
    fflush(stdout);
    exit(1);
  }
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

/*     CALCULIX - A 3-dimensional finite element program                 */
/*              Copyright (C) 1998 Guido Dhondt                          */
/*     This program is free software; you can redistribute it and/or     */
/*     modify it under the terms of the GNU General Public License as    */
/*     published by the Free Software Foundation; either version 2 of    */
/*     the License, or (at your option) any later version.               */

#ifdef MUMPS

#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include "CalculiX.h"
#include "mumps.h"
#include <dmumps_c.h>

static DMUMPS_STRUC_C id_cp;
static ITG mumps_cp_initialized = 0;

void mumps_factor_cp(double *ad, double *au, double *adb, double *aub,
                     double *sigma, ITG *icol, ITG *irow,
                     ITG *neq, ITG *nzs, ITG *symmetryflag, ITG *inputformat,
                     ITG *jq, ITG *nzs3, ITG *iexpl){

  ITG i, j, k, l;
  ITG nnz;
  char *env;
  ITG nthread = 1;

  if(*neq == 0) return;

  if(mumps_cp_initialized){
    mumps_cleanup_cp(neq, symmetryflag, inputformat);
  }

  if(*iexpl <= 1){
    if(*symmetryflag == 0){
      printf(" Factoring the contact system of equations using the symmetric MUMPS solver\n");
    }else{
      printf(" Factoring the contact system of equations using the unsymmetric MUMPS solver\n");
    }
  }

  /* 1. Initialize MUMPS contact instance */
  if(!mumps_cp_initialized){
    id_cp.comm_fortran = -987654;
    id_cp.par = 1;
    id_cp.sym = (*symmetryflag == 0) ? 2 : 0;
    id_cp.job = -1;
    dmumps_c(&id_cp);
    mumps_cp_initialized = 1;
  }

  /* 2. Thread count */
  env = getenv("CCX_NPROC_EQUATION_SOLVER");
  if(env){
    nthread = atoi(env);
  }else{
    env = getenv("OMP_NUM_THREADS");
    if(env){ nthread = atoi(env); }
  }
  if(nthread < 1) nthread = 1;

  /* 3. Control parameters */
  id_cp.icntl[0] = -1;  /* Quiet error stream */
  id_cp.icntl[1] = -1;  /* Quiet diagnostic stream */
  id_cp.icntl[2] = -1;  /* Quiet global stream */
  id_cp.icntl[3] = 0;   /* Printing level 0 */

  id_cp.icntl[5] = getenv("CCX_MUMPS_ICNTL6") ? atoi(getenv("CCX_MUMPS_ICNTL6")) : (*symmetryflag == 0 ? 0 : 7);
  id_cp.icntl[6] = getenv("CCX_MUMPS_ICNTL7") ? atoi(getenv("CCX_MUMPS_ICNTL7")) : 7;
  id_cp.icntl[7] = getenv("CCX_MUMPS_ICNTL8") ? atoi(getenv("CCX_MUMPS_ICNTL8")) : 0;
  id_cp.icntl[15] = getenv("CCX_MUMPS_ICNTL16") ? atoi(getenv("CCX_MUMPS_ICNTL16")) : (MUMPS_INT)nthread;
  id_cp.icntl[23] = 1; /* Null pivot detection */

  if(*symmetryflag == 0){
    id_cp.cntl[0] = getenv("CCX_MUMPS_CNTL1") ? atof(getenv("CCX_MUMPS_CNTL1")) : 0.0;
  }

  id_cp.n = *neq;

  /* 4. Sparse matrix coordinate format (COO) assembly */
  if(*symmetryflag == 0){
    /* Symmetric matrix: Lower triangular part */
    nnz = *neq + *nzs;
    id_cp.nz = nnz;
    NNEW(id_cp.irn, MUMPS_INT, nnz);
    NNEW(id_cp.jcn, MUMPS_INT, nnz);
    NNEW(id_cp.a, double, nnz);

    k = 0;
    l = 0;
    for(i = 0; i < *neq; i++){
      for(j = 0; j < icol[i]; j++){
        id_cp.irn[k] = (MUMPS_INT)irow[l];
        id_cp.jcn[k] = (MUMPS_INT)(i + 1);
        id_cp.a[k]   = (*sigma == 0.) ? au[l] : (au[l] - (*sigma)*aub[l]);
        k++;
        l++;
      }
      /* Diagonal element */
      id_cp.irn[k] = (MUMPS_INT)(i + 1);
      id_cp.jcn[k] = (MUMPS_INT)(i + 1);
      id_cp.a[k]   = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
      k++;
    }
  }else{
    /* Unsymmetric matrix */
    if(*inputformat == 3){
      nnz = *neq + *nzs;
      id_cp.nz = nnz;
      NNEW(id_cp.irn, MUMPS_INT, nnz);
      NNEW(id_cp.jcn, MUMPS_INT, nnz);
      NNEW(id_cp.a, double, nnz);

      k = 0;
      ITG k2 = 0;
      for(i = 0; i < *neq; i++){
        for(j = 0; j < icol[i]; j++){
          id_cp.irn[k2] = (MUMPS_INT)irow[k];
          id_cp.jcn[k2] = (MUMPS_INT)(i + 1);
          id_cp.a[k2]   = (*sigma == 0.) ? au[k] : (au[k] - (*sigma)*aub[k]);
          k2++;
          k++;
        }
      }
      for(i = 0; i < *neq; i++){
        id_cp.irn[k2] = (MUMPS_INT)(i + 1);
        id_cp.jcn[k2] = (MUMPS_INT)(i + 1);
        id_cp.a[k2]   = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
        k2++;
      }
      id_cp.nz = k2;
    }else if(*inputformat == 1){
      nnz = *neq + 2*(*nzs);
      id_cp.nz = nnz;
      NNEW(id_cp.irn, MUMPS_INT, nnz);
      NNEW(id_cp.jcn, MUMPS_INT, nnz);
      NNEW(id_cp.a, double, nnz);

      k = 0;
      ITG idx = 0;
      for(i = 0; i < *neq; i++){
        for(j = 0; j < icol[i]; j++){
          id_cp.irn[idx] = (MUMPS_INT)irow[k];
          id_cp.jcn[idx] = (MUMPS_INT)(i + 1);
          id_cp.a[idx]   = (*sigma == 0.) ? au[k] : (au[k] - (*sigma)*aub[k]);
          idx++;
          k++;
        }
      }
      for(i = 0; i < *neq; i++){
        for(j = jq[i]-1; j < jq[i+1]-1; j++){
          id_cp.irn[idx] = (MUMPS_INT)(i + 1);
          id_cp.jcn[idx] = (MUMPS_INT)irow[j];
          id_cp.a[idx]   = (*sigma == 0.) ? au[j+*nzs3] : (au[j+*nzs3] - (*sigma)*aub[j+*nzs3]);
          idx++;
        }
      }
      for(i = 0; i < *neq; i++){
        id_cp.irn[idx] = (MUMPS_INT)(i + 1);
        id_cp.jcn[idx] = (MUMPS_INT)(i + 1);
        id_cp.a[idx]   = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
        idx++;
      }
    }
  }

  /* 5. Symbolic Analysis (JOB = 1) */
  id_cp.job = 1;
  dmumps_c(&id_cp);
  if(id_cp.infog[0] < 0){
    printf(" *ERROR in MUMPS contact analysis phase: INFOG(1) = %d\n", (int)id_cp.infog[0]);
    exit(1);
  }

  /* 6. Numerical Factorization (JOB = 2) */
  id_cp.job = 2;
  dmumps_c(&id_cp);
  if(id_cp.infog[0] < 0){
    printf(" *ERROR in MUMPS contact factorization phase: INFOG(1) = %d\n", (int)id_cp.infog[0]);
    exit(1);
  }
}

void mumps_solve_cp(double *b, ITG *neq, ITG *symmetryflag, ITG *inputformat, ITG *nrhs){
  id_cp.rhs  = b;
  id_cp.nrhs = (MUMPS_INT)abs(*nrhs);
  id_cp.lrhs = (MUMPS_INT)(*neq);

  if (*nrhs < 0) {
    id_cp.icntl[8] = 0;
  } else {
    id_cp.icntl[8] = 1;
  }

  id_cp.job  = 3;
  dmumps_c(&id_cp);
  if(id_cp.infog[0] < 0){
    printf(" *ERROR in MUMPS contact solve phase: INFOG(1) = %d\n", (int)id_cp.infog[0]);
    fflush(stdout);
    exit(1);
  }
}

void mumps_cleanup_cp(ITG *neq, ITG *symmetryflag, ITG *inputformat){
  if(mumps_cp_initialized){
    id_cp.job = -2;
    dmumps_c(&id_cp);
    mumps_cp_initialized = 0;
  }
  if(id_cp.irn){ SFREE(id_cp.irn); id_cp.irn = NULL; }
  if(id_cp.jcn){ SFREE(id_cp.jcn); id_cp.jcn = NULL; }
  if(id_cp.a)  { SFREE(id_cp.a);   id_cp.a = NULL; }
}

#endif

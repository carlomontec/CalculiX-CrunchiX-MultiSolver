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

#ifdef ACCELERATE_SOLVER

#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#ifndef __CLAPACK_H
#define __CLAPACK_H
#endif
#include <Accelerate/Accelerate.h>
#include "CalculiX.h"
#include "accelerate_solver.h"

static SparseMatrix_Double acc_A;
static SparseOpaqueFactorization_Double acc_factorization;
static ITG acc_initialized = 0;
static ITG acc_prev_neq = 0;
static ITG acc_prev_nnz = 0;
static ITG acc_prev_sym = -1;
static ITG acc_prev_inputformat = -1;
static int *coo_rows = NULL;
static int *coo_cols = NULL;
static double *coo_vals = NULL;
static long *csc_col_starts = NULL;
static int *csc_row_indices = NULL;
static double *csc_values = NULL;

/* Thread/env configuration only needs to happen once per process, not
   once per accelerate_factor() call. */
static ITG acc_env_configured = 0;
static ITG acc_nthread = 1;

static void accelerate_configure_env(void) {
  char *env;

  if(acc_env_configured) return;

  env = getenv("CCX_NPROC_EQUATION_SOLVER");
  if(env){
    acc_nthread = atoi(env);
  }else{
    env = getenv("OMP_NUM_THREADS");
    if(env){ acc_nthread = atoi(env); }
  }
  if(acc_nthread < 1) acc_nthread = 1;

  if(!getenv("VECLIB_MAXIMUM_THREADS")){
    char th_buf[32];
    snprintf(th_buf, sizeof(th_buf), "%d", (int)acc_nthread);
    setenv("VECLIB_MAXIMUM_THREADS", th_buf, 0);
  }

  acc_env_configured = 1;
}

void accelerate_cleanup(ITG *neq, ITG *symmetryflag, ITG *inputformat) {
  if(acc_initialized){
    if(acc_factorization.status >= 0 || acc_factorization.numericFactorization != NULL){
      SparseCleanup(acc_factorization);
    }
    if(acc_prev_sym != 0){
      SparseCleanup(acc_A);
    }
    acc_initialized = 0;
    acc_prev_neq = 0;
    acc_prev_nnz = 0;
    acc_prev_sym = -1;
    acc_prev_inputformat = -1;
  }

  if(coo_rows) { SFREE(coo_rows); coo_rows = NULL; }
  if(coo_cols) { SFREE(coo_cols); coo_cols = NULL; }
  if(coo_vals) { SFREE(coo_vals); coo_vals = NULL; }
  if(csc_col_starts)  { SFREE(csc_col_starts); csc_col_starts = NULL; }
  if(csc_row_indices) { SFREE(csc_row_indices); csc_row_indices = NULL; }
  if(csc_values)      { SFREE(csc_values); csc_values = NULL; }
}

void accelerate_factor(double *ad, double *au, double *adb, double *aub,
                       double *sigma, ITG *icol, ITG *irow,
                       ITG *neq, ITG *nzs, ITG *symmetryflag, ITG *inputformat,
                       ITG *jq, ITG *nzs3) {

  ITG i, j, k, l;
  ITG nnz = 0;
  char *env;
  SparseAttributes_t attributes;
  SparseFactorization_t fact_type;
  SparseSymbolicFactorOptions sfoptions;
  SparseNumericFactorOptions nfoptions;
  ITG acc_A_built = 0;

  if(*neq == 0) return;

  /* If symmetry or dimensions changed, perform full cleanup */
  if(acc_initialized && (acc_prev_sym != *symmetryflag || acc_prev_neq != *neq || acc_prev_inputformat != *inputformat)){
    accelerate_cleanup(neq, symmetryflag, inputformat);
  }

  if(*symmetryflag == 0){
    printf(" Factoring the system of equations using Apple Accelerate (Symmetric LDLT_TPP)\n");
  }else{
    printf(" Factoring the system of equations using Apple Accelerate (Unsymmetric QR)\n");
  }

  /* 1. Configure thread count for vecLib / Accelerate (once per process) */
  accelerate_configure_env();
  printf(" number of threads = %d\n\n", (int)acc_nthread);

  /* 2. Assemble matrix format */
  if(*symmetryflag == 0){
    /*
     * Symmetric matrix: Lower triangular part.
     * CCX stores subdiagonal entries column by column in au, diagonal in ad.
     * Default: Fast parallel SparseFactorizationLDLT with automatic fallback to
     * SparseFactorizationLDLTTPP if indefinite pivots are detected.
     */
    fact_type = SparseFactorizationLDLT;
    env = getenv("CCX_ACCELERATE_FACT");
    if(env){
      if(strcmp(env, "CHOLESKY") == 0 || strcmp(env, "cholesky") == 0){
        fact_type = SparseFactorizationCholesky;
      }else if(strcmp(env, "LDLTTPP") == 0 || strcmp(env, "ldlttpp") == 0){
        fact_type = SparseFactorizationLDLTTPP;
      }else if(strcmp(env, "LDLT") == 0 || strcmp(env, "ldlt") == 0){
        fact_type = SparseFactorizationLDLT;
      }
    }

    attributes = (SparseAttributes_t){
      .transpose = false,
      .triangle = SparseLowerTriangle,
      .kind = SparseSymmetric,
      ._reserved = 0,
      ._allocatedBySparse = false
    };

    nnz = *neq + *nzs;
    if(csc_col_starts == NULL || acc_prev_nnz != nnz || acc_prev_neq != *neq){
      if(csc_col_starts)  SFREE(csc_col_starts);
      if(csc_row_indices) SFREE(csc_row_indices);
      if(csc_values)      SFREE(csc_values);
      NNEW(csc_col_starts, long, *neq + 1);
      NNEW(csc_row_indices, int, nnz);
      NNEW(csc_values, double, nnz);
      acc_prev_nnz = nnz;
    }

    csc_col_starts[0] = 0;
    k = 0;
    l = 0;
    for(i = 0; i < *neq; i++){
      /* Diagonal entry (i, i) */
      csc_row_indices[k] = (int)i;
      csc_values[k] = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
      k++;

      /* Subdiagonal entries */
      for(j = 0; j < icol[i]; j++){
        csc_row_indices[k] = (int)(irow[l] - 1);
        csc_values[k] = (*sigma == 0.) ? au[l] : (au[l] - (*sigma)*aub[l]);
        k++;
        l++;
      }
      csc_col_starts[i+1] = (long)k;
    }

    acc_A = (SparseMatrix_Double){
      .structure = (SparseMatrixStructure){
        .rowCount = (int)(*neq),
        .columnCount = (int)(*neq),
        .columnStarts = csc_col_starts,
        .rowIndices = csc_row_indices,
        .attributes = attributes,
        .blockSize = 1
      },
      .data = csc_values
    };

    /* Fast In-Place Numeric Refactorization for Symmetric Systems */
    if(acc_initialized){
      SparseRefactor(acc_A, &acc_factorization);
      if(acc_factorization.status == SparseStatusOK){
        return;
      }
      if(acc_factorization.status >= 0 || acc_factorization.numericFactorization != NULL){
        SparseCleanup(acc_factorization);
      }
      acc_initialized = 0;
    }

  }else{
    /*
     * Unsymmetric matrix.
     * Factorization: SparseFactorizationQR
     */
    fact_type = SparseFactorizationQR;
    attributes = (SparseAttributes_t){
      .transpose = false,
      .triangle = SparseLowerTriangle,
      .kind = SparseOrdinary,
      ._reserved = 0,
      ._allocatedBySparse = false
    };

    if(*inputformat == 3){
      /* General unsymmetric format */
      nnz = *neq + *nzs;
      if(coo_rows == NULL || acc_prev_nnz != nnz){
        if(coo_rows) SFREE(coo_rows);
        if(coo_cols) SFREE(coo_cols);
        if(coo_vals) SFREE(coo_vals);
        NNEW(coo_rows, int, nnz);
        NNEW(coo_cols, int, nnz);
        NNEW(coo_vals, double, nnz);
        acc_prev_nnz = nnz;
      }

      k = 0;
      ITG k2 = 0;
      for(i = 0; i < *neq; i++){
        for(j = 0; j < icol[i]; j++){
          coo_cols[k2] = (int)i;
          coo_rows[k2] = (int)(irow[k] - 1);
          coo_vals[k2] = (*sigma == 0.) ? au[k] : (au[k] - (*sigma)*aub[k]);
          k2++;
          k++;
        }
      }
      for(i = 0; i < *neq; i++){
        coo_cols[k2] = (int)i;
        coo_rows[k2] = (int)i;
        coo_vals[k2] = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
        k2++;
      }
      nnz = k2;
    }else{
      /* Structurally symmetric, numerically asymmetric (inputformat == 1) */
      nnz = *neq + 2*(*nzs);
      if(coo_rows == NULL || acc_prev_nnz != nnz){
        if(coo_rows) SFREE(coo_rows);
        if(coo_cols) SFREE(coo_cols);
        if(coo_vals) SFREE(coo_vals);
        NNEW(coo_rows, int, nnz);
        NNEW(coo_cols, int, nnz);
        NNEW(coo_vals, double, nnz);
        acc_prev_nnz = nnz;
      }

      k = 0;
      ITG idx = 0;
      /* Lower triangle */
      for(i = 0; i < *neq; i++){
        for(j = 0; j < icol[i]; j++){
          coo_rows[idx] = (int)(irow[k] - 1);
          coo_cols[idx] = (int)i;
          coo_vals[idx] = (*sigma == 0.) ? au[k] : (au[k] - (*sigma)*aub[k]);
          idx++;
          k++;
        }
      }
      /* Upper triangle */
      for(i = 0; i < *neq; i++){
        for(j = jq[i]-1; j < jq[i+1]-1; j++){
          coo_rows[idx] = (int)i;
          coo_cols[idx] = (int)(irow[j] - 1);
          coo_vals[idx] = (*sigma == 0.) ? au[j+*nzs3] : (au[j+*nzs3] - (*sigma)*aub[j+*nzs3]);
          idx++;
        }
      }
      /* Diagonal */
      for(i = 0; i < *neq; i++){
        coo_rows[idx] = (int)i;
        coo_cols[idx] = (int)i;
        coo_vals[idx] = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
        idx++;
      }
      nnz = idx;
    }

    /* Fast In-Place Numeric Refactorization for Unsymmetric Systems */
    if(acc_initialized){
      SparseCleanup(acc_A);
      acc_A = SparseConvertFromCoordinate((int)(*neq), (int)(*neq), (long)nnz, 1,
                                          attributes, coo_rows, coo_cols, coo_vals);
      acc_A_built = 1;
      SparseRefactor(acc_A, &acc_factorization);
      if(acc_factorization.status == SparseStatusOK){
        return;
      }
      if(acc_factorization.status >= 0 || acc_factorization.numericFactorization != NULL){
        SparseCleanup(acc_factorization);
      }
      acc_initialized = 0;
    }

    /* Only (re)build acc_A here if it wasn't already built by the refactor
       attempt above - avoids converting the same COO data twice. */
    if(!acc_A_built){
      acc_A = SparseConvertFromCoordinate((int)(*neq), (int)(*neq), (long)nnz, 1,
                                          attributes, coo_rows, coo_cols, coo_vals);
    }
  }

  /* 5. Configure symbolic and numeric factorization options */
  /* Adaptive ordering: Metis nested dissection for 3D continuum meshes (neq >= 5000), AMD for small models */
  SparseOrder_t ord = (*neq >= 5000) ? SparseOrderMetis : SparseOrderAMD;
  env = getenv("CCX_ACCELERATE_ORDER");
  if(env){
    if(strcmp(env, "AMD") == 0 || strcmp(env, "amd") == 0){
      ord = SparseOrderAMD;
    }else if(strcmp(env, "METIS") == 0 || strcmp(env, "metis") == 0){
      ord = SparseOrderMetis;
    }
  }

  sfoptions = (SparseSymbolicFactorOptions){
    .control = SparseDefaultControl,
    .orderMethod = ord,
    .order = NULL,
    .ignoreRowsAndColumns = NULL,
    .malloc = malloc,
    .free = free,
    .reportError = NULL
  };

  nfoptions = (SparseNumericFactorOptions){
    .control = SparseDefaultControl,
    .scalingMethod = SparseScalingDefault,
    .scaling = NULL,
    .pivotTolerance = 0.01,
    .zeroTolerance = 1e-15
  };

  /* 6. Compute Full Symbolic and Numerical Factorization */
  acc_factorization = SparseFactor(fact_type, acc_A, sfoptions, nfoptions);
  if(acc_factorization.status < 0 && fact_type != SparseFactorizationLDLTTPP && *symmetryflag == 0){
    /* Fallback to robust threshold pivoting LDL^T for indefinite systems */
    if(acc_factorization.status >= 0 || acc_factorization.numericFactorization != NULL){
      SparseCleanup(acc_factorization);
    }
    fact_type = SparseFactorizationLDLTTPP;
    acc_factorization = SparseFactor(fact_type, acc_A, sfoptions, nfoptions);
  }
  if(acc_factorization.status < 0){
    printf(" *ERROR in Apple Accelerate factorization: status = %d\n", (int)acc_factorization.status);
    exit(1);
  }

  acc_initialized = 1;
  acc_prev_neq = *neq;
  acc_prev_sym = *symmetryflag;
  acc_prev_inputformat = *inputformat;
}

void accelerate_solve(double *b, ITG *neq, ITG *symmetryflag, ITG *inputformat, ITG *nrhs) {
  if(!acc_initialized || *neq == 0) return;

  DenseMatrix_Double XB = {
    .rowCount = (int)(*neq),
    .columnCount = (int)(*nrhs > 0 ? *nrhs : -*nrhs),
    .columnStride = (int)(*neq),
    .attributes = (SparseAttributes_t){
      .transpose = (*nrhs < 0),
      .triangle = SparseLowerTriangle,
      .kind = SparseOrdinary,
      ._reserved = 0,
      ._allocatedBySparse = false
    },
    .data = b
  };

  /* Solve AX = B in-place; solution vector X is stored back directly into b */
  SparseSolve(acc_factorization, XB);
}

void accelerate_main(double *ad, double *au, double *adb, double *aub,
                     double *sigma, double *b, ITG *icol, ITG *irow,
                     ITG *neq, ITG *nzs, ITG *symmetryflag, ITG *inputformat,
                     ITG *jq, ITG *nzs3, ITG *nrhs) {

  if(*neq == 0) return;

  accelerate_factor(ad, au, adb, aub, sigma, icol, irow,
                    neq, nzs, symmetryflag, inputformat, jq, nzs3);

  accelerate_solve(b, neq, symmetryflag, inputformat, nrhs);

  /* No cleanup here. accelerate_factor() already detects a genuine change
     in problem shape (neq / symmetryflag / inputformat) on the *next* call
     and cleans up + refactors from scratch then. Unconditionally cleaning
     up after every solve, as before, discarded the cached factorization
     and forced a full symbolic + numeric refactorization on every call,
     even across Newton iterations or multiple RHS solves against the same
     unchanged matrix. */
}

#endif /* ACCELERATE_SOLVER */
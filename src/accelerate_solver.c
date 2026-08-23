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
static int *coo_rows = NULL;
static int *coo_cols = NULL;
static double *coo_vals = NULL;

void accelerate_factor(double *ad, double *au, double *adb, double *aub,
                       double *sigma, ITG *icol, ITG *irow,
                       ITG *neq, ITG *nzs, ITG *symmetryflag, ITG *inputformat,
                       ITG *jq, ITG *nzs3) {

  ITG i, j, k, l;
  ITG nnz;
  char *env;
  ITG nthread = 1;
  SparseAttributes_t attributes;
  SparseFactorization_t fact_type;
  SparseSymbolicFactorOptions sfoptions;
  SparseNumericFactorOptions nfoptions;

  if(*neq == 0) return;

  /* Reset and release previous solver instance if called repeatedly (e.g. contact iterations) */
  if(acc_initialized){
    accelerate_cleanup(neq, symmetryflag, inputformat);
  }

  if(*symmetryflag == 0){
    printf(" Factoring the system of equations using Apple Accelerate (Symmetric LDLT_TPP)\n");
  }else{
    printf(" Factoring the system of equations using Apple Accelerate (Unsymmetric QR)\n");
  }

  /* 1. Configure thread count for vecLib / Accelerate */
  env = getenv("CCX_NPROC_EQUATION_SOLVER");
  if(env){
    nthread = atoi(env);
  }else{
    env = getenv("OMP_NUM_THREADS");
    if(env){ nthread = atoi(env); }
  }
  if(nthread < 1) nthread = 1;
  
  /* If VECLIB_MAXIMUM_THREADS is not explicitly set, configure from CCX/OMP */
  if(!getenv("VECLIB_MAXIMUM_THREADS")){
    char th_buf[32];
    snprintf(th_buf, sizeof(th_buf), "%d", (int)nthread);
    setenv("VECLIB_MAXIMUM_THREADS", th_buf, 0);
  }
  printf(" number of threads = %d\n\n", (int)nthread);

  /* 2. Build 0-based Coordinate (COO) representation from CCX 1-based format */
  if(*symmetryflag == 0){
    /*
     * Symmetric matrix: Lower triangular part.
     * CCX stores subdiagonal entries column by column in au, diagonal in ad.
     * Factorization: SparseFactorizationLDLTTPP (LDL^T with Threshold Partial Pivoting)
     * Rationale: Robust against indefinite systems from contact, Lagrange multipliers,
     * MPCs, or negative eigenvalue shifts (K - sigma*M), while running fully parallel on Apple Silicon.
     */
    fact_type = SparseFactorizationLDLTTPP;
    attributes = (SparseAttributes_t){
      .transpose = false,
      .triangle = SparseLowerTriangle,
      .kind = SparseSymmetric,
      ._reserved = 0,
      ._allocatedBySparse = false
    };

    nnz = *neq + *nzs;
    NNEW(coo_rows, int, nnz);
    NNEW(coo_cols, int, nnz);
    NNEW(coo_vals, double, nnz);

    k = 0;
    l = 0;
    for(i = 0; i < *neq; i++){
      for(j = 0; j < icol[i]; j++){
        coo_rows[k] = (int)(irow[l] - 1); /* 1-based to 0-based */
        coo_cols[k] = (int)i;
        coo_vals[k] = (*sigma == 0.) ? au[l] : (au[l] - (*sigma)*aub[l]);
        k++;
        l++;
      }
      /* Diagonal entry */
      coo_rows[k] = (int)i;
      coo_cols[k] = (int)i;
      coo_vals[k] = (*sigma == 0.) ? ad[i] : (ad[i] - (*sigma)*adb[i]);
      k++;
    }
  }else{
    /*
     * Unsymmetric matrix.
     * Factorization: SparseFactorizationQR
     * Rationale: QR decomposition guarantees unconditionally stable solution without
     * breakdown for general unsymmetric systems (e.g. CFD or non-associated plasticity).
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
      NNEW(coo_rows, int, nnz);
      NNEW(coo_cols, int, nnz);
      NNEW(coo_vals, double, nnz);

      k = 0;
      ITG k2 = 0;
      for(i = 0; i < *neq; i++){
        for(j = 0; j < icol[i]; j++){
          if(au[k] > 1.e-12 || au[k] < -1.e-12){
            coo_cols[k2] = (int)i;
            coo_rows[k2] = (int)(irow[k] - 1);
            coo_vals[k2] = (*sigma == 0.) ? au[k] : (au[k] - (*sigma)*aub[k]);
            k2++;
          }
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
      NNEW(coo_rows, int, nnz);
      NNEW(coo_cols, int, nnz);
      NNEW(coo_vals, double, nnz);

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
  }

  /* 3. Convert COO to Apple Accelerate internal Compressed Sparse Column (CSC) */
  acc_A = SparseConvertFromCoordinate((int)(*neq), (int)(*neq), (long)nnz, 1,
                                      attributes, coo_rows, coo_cols, coo_vals);

  /* 4. Configure symbolic and numeric factorization options */
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

  /* 5. Compute Symbolic and Numerical Factorization */
  acc_factorization = SparseFactor(fact_type, acc_A, sfoptions, nfoptions);
  if(acc_factorization.status < 0){
    printf(" *ERROR in Apple Accelerate factorization: status = %d\n", (int)acc_factorization.status);
    exit(1);
  }

  acc_initialized = 1;
}

void accelerate_solve(double *b, ITG *neq, ITG *symmetryflag, ITG *inputformat, ITG *nrhs) {
  if(!acc_initialized || *neq == 0) return;

  DenseMatrix_Double XB = {
    .rowCount = (int)(*neq),
    .columnCount = (int)(*nrhs),
    .columnStride = (int)(*neq),
    .attributes = (SparseAttributes_t){
      .transpose = false,
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

void accelerate_cleanup(ITG *neq, ITG *symmetryflag, ITG *inputformat) {
  if(acc_initialized){
    if(acc_factorization.status >= 0 || acc_factorization.numericFactorization != NULL){
      SparseCleanup(acc_factorization);
    }
    SparseCleanup(acc_A);
    acc_initialized = 0;
  }

  if(coo_rows){ SFREE(coo_rows); coo_rows = NULL; }
  if(coo_cols){ SFREE(coo_cols); coo_cols = NULL; }
  if(coo_vals){ SFREE(coo_vals); coo_vals = NULL; }
}

void accelerate_main(double *ad, double *au, double *adb, double *aub,
                     double *sigma, double *b, ITG *icol, ITG *irow,
                     ITG *neq, ITG *nzs, ITG *symmetryflag, ITG *inputformat,
                     ITG *jq, ITG *nzs3, ITG *nrhs) {

  if(*neq == 0) return;

  accelerate_factor(ad, au, adb, aub, sigma, icol, irow,
                    neq, nzs, symmetryflag, inputformat, jq, nzs3);

  accelerate_solve(b, neq, symmetryflag, inputformat, nrhs);

  accelerate_cleanup(neq, symmetryflag, inputformat);
}

#endif /* ACCELERATE_SOLVER */

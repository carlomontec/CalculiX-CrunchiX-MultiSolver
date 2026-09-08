/*     CalculiX - A 3-dimensional finite element program                 */
/*     JSON Export Module for Automated Pipelines (Python/Julia/MATLAB)  */

#ifndef JSON_EXPORT_H
#define JSON_EXPORT_H

#include "CalculiX.h"

#ifdef __cplusplus
extern "C" {
#endif

/* State query & control */
int json_is_active(void);
void json_set_active(int active);

/* Lifecycle */
void json_init(const char *jobname, const char *solver_name);
void json_set_meta_stats(ITG *nk, ITG *ne, ITG *neq, ITG num_cpus);
void json_finalize(int exit_code, double total_time);

/* Step & Increment */
void json_start_step(ITG istep, const char *step_type);
void json_start_increment(ITG iinc, double time, double ttime);
void json_end_step(ITG istep);

/* Modal & Buckling results */
void json_export_eigenvalues(double *d, ITG nev, double fmin, double fmax);
void json_export_modal_mass(ITG nev, double *part, double *toteffmass, double *effmodmass, double *fraction);
void json_export_buckling(double *d, ITG nev);

/* Nodal, Element, and Energy print results */
void json_export_results(double *v, double *fn, double *stx, double *stn,
                         double *een, double *ener, double *energy,
                         char *prlab, char *prset, ITG nprint,
                         char *set, ITG nset, ITG *istartset, ITG *iendset, ITG *ialset,
                         ITG *ipkon, ITG *kon, char *lakon, ITG nk, ITG ne,
                         ITG *mi, double time, double ttime, ITG iinc);

#ifdef __cplusplus
}
#endif

#endif /* JSON_EXPORT_H */


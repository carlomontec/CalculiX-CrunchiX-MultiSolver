/*     CalculiX - A 3-dimensional finite element program                 */
/*     JSON Export Module for Automated Pipelines (Python/Julia/MATLAB)  */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include "CalculiX.h"
#include "json_export.h"

/* Internal dynamic buffer for JSON generation */
typedef struct {
  char *data;
  size_t size;
  size_t capacity;
} JsonBuffer;

static int g_json_active = 0;
static char g_jobname[256] = "";
static char g_solver_name[64] = "DEFAULT";
static ITG g_num_nodes = 0;
static ITG g_num_elements = 0;
static ITG g_num_equations = 0;
static ITG g_num_cpus = 1;

/* Steps tracking buffer */
static JsonBuffer g_steps_buf = {NULL, 0, 0};
static int g_step_count = 0;
static int g_current_step_open = 0;
static int g_current_inc_open = 0;
static int g_has_modes = 0;
static int g_has_buckling = 0;
static int g_has_node_sets = 0;
static int g_has_elem_sets = 0;

static void buf_init(JsonBuffer *b, size_t initial_cap) {
  b->capacity = initial_cap ? initial_cap : 4096;
  b->data = (char *)malloc(b->capacity);
  b->size = 0;
  if (b->data) b->data[0] = '\0';
}

static void buf_free(JsonBuffer *b) {
  if (b->data) {
    free(b->data);
    b->data = NULL;
  }
  b->size = 0;
  b->capacity = 0;
}

static void buf_append(JsonBuffer *b, const char *str) {
  if (!b->data) buf_init(b, 4096);
  size_t len = strlen(str);
  if (b->size + len + 1 >= b->capacity) {
    while (b->size + len + 1 >= b->capacity) {
      b->capacity *= 2;
    }
    b->data = (char *)realloc(b->data, b->capacity);
  }
  memcpy(b->data + b->size, str, len);
  b->size += len;
  b->data[b->size] = '\0';
}

static void buf_printf(JsonBuffer *b, const char *fmt, ...) {
  char temp[2048];
  va_list args;
  va_start(args, fmt);
  vsnprintf(temp, sizeof(temp), fmt, args);
  va_end(args);
  buf_append(b, temp);
}

static void buf_print_float(JsonBuffer *b, double val) {
  if (isnan(val) || isinf(val)) {
    buf_append(b, "null");
  } else {
    buf_printf(b, "%.10e", val);
  }
}

int json_is_active(void) {
  return g_json_active;
}

void json_set_active(int active) {
  g_json_active = active;
}

void json_init(const char *jobname, const char *solver_name) {
  if (!jobname) return;
  size_t len = 0;
  while (jobname[len] && jobname[len] != ' ' && len < sizeof(g_jobname) - 1) {
    g_jobname[len] = jobname[len];
    len++;
  }
  g_jobname[len] = '\0';

  /* Strip trailing .inp if present */
  if (len > 4 && strcmp(&g_jobname[len - 4], ".inp") == 0) {
    g_jobname[len - 4] = '\0';
  }

  if (solver_name) {
    strncpy(g_solver_name, solver_name, sizeof(g_solver_name) - 1);
    g_solver_name[sizeof(g_solver_name) - 1] = '\0';
  }

  buf_free(&g_steps_buf);
  buf_init(&g_steps_buf, 16384);
  g_step_count = 0;
  g_current_step_open = 0;
  g_current_inc_open = 0;
}

void json_set_meta_stats(ITG *nk, ITG *ne, ITG *neq, ITG num_cpus) {
  if (nk) g_num_nodes = *nk;
  if (ne) g_num_elements = *ne;
  if (neq) g_num_equations = neq[1];
  if (num_cpus > 0) g_num_cpus = num_cpus;
}

static ITG g_last_iinc = -1;
static int g_step_has_increments = 0;

void json_start_step(ITG istep, const char *step_type) {
  if (!g_json_active) return;

  if (g_current_step_open) {
    json_end_step(istep - 1);
  }

  if (g_step_count > 0) {
    buf_append(&g_steps_buf, ",\n");
  }

  buf_printf(&g_steps_buf, "    {\n      \"step_number\": %d,\n", (int)istep);
  buf_printf(&g_steps_buf, "      \"type\": \"%s\",\n", step_type ? step_type : "UNKNOWN");
  buf_append(&g_steps_buf, "      \"converged\": true");

  g_current_step_open = 1;
  g_current_inc_open = 0;
  g_step_has_increments = 0;
  g_last_iinc = -1;
  g_has_modes = 0;
  g_has_buckling = 0;
  g_has_node_sets = 0;
  g_has_elem_sets = 0;
  g_step_count++;
}

void json_end_step(ITG istep) {
  if (!g_json_active || !g_current_step_open) return;

  if (g_current_inc_open) {
    buf_append(&g_steps_buf, "\n        }");
    g_current_inc_open = 0;
  }

  if (g_step_has_increments) {
    buf_append(&g_steps_buf, "\n      ]");
    g_step_has_increments = 0;
  }

  buf_append(&g_steps_buf, "\n    }");
  g_current_step_open = 0;
  g_last_iinc = -1;
}

void json_export_eigenvalues(double *d, ITG nev, double fmin, double fmax) {
  if (!g_json_active || !g_current_step_open || !d || nev <= 0) return;

  double pi = 4.0 * atan(1.0);
  buf_append(&g_steps_buf, ",\n      \"modes\": [\n");

  int count = 0;
  for (ITG j = 0; j < nev; j++) {
    double eig = d[j];
    double rad_s = (eig >= 0.0) ? sqrt(eig) : 0.0;
    double hz = rad_s / (2.0 * pi);

    if (fmin > -0.5 && fmin * fmin > eig) continue;
    if (fmax > -0.5 && fmax * fmax < eig) break;

    if (count > 0) buf_append(&g_steps_buf, ",\n");
    buf_printf(&g_steps_buf, "        {\n");
    buf_printf(&g_steps_buf, "          \"mode_number\": %d,\n", (int)(j + 1));
    buf_append(&g_steps_buf, "          \"eigenvalue\": "); buf_print_float(&g_steps_buf, eig);
    buf_append(&g_steps_buf, ",\n          \"frequency_rad_s\": "); buf_print_float(&g_steps_buf, rad_s);
    buf_append(&g_steps_buf, ",\n          \"frequency_hz\": "); buf_print_float(&g_steps_buf, hz);
    buf_append(&g_steps_buf, "\n        }");
    count++;
  }

  buf_append(&g_steps_buf, "\n      ]");
  g_has_modes = 1;
}

void json_export_modal_mass(ITG nev, double *part, double *toteffmass, double *effmodmass, double *fraction) {
  if (!g_json_active || !g_current_step_open || nev <= 0) return;

  /* Append modal masses, participation factors, and total effective mass */
  if (toteffmass) {
    buf_append(&g_steps_buf, ",\n      \"total_effective_mass\": {\n");
    buf_append(&g_steps_buf, "        \"x\": "); buf_print_float(&g_steps_buf, toteffmass[0]);
    buf_append(&g_steps_buf, ", \"y\": "); buf_print_float(&g_steps_buf, toteffmass[1]);
    buf_append(&g_steps_buf, ", \"z\": "); buf_print_float(&g_steps_buf, toteffmass[2]);
    buf_append(&g_steps_buf, ",\n        \"rx\": "); buf_print_float(&g_steps_buf, toteffmass[3]);
    buf_append(&g_steps_buf, ", \"ry\": "); buf_print_float(&g_steps_buf, toteffmass[4]);
    buf_append(&g_steps_buf, ", \"rz\": "); buf_print_float(&g_steps_buf, toteffmass[5]);
    buf_append(&g_steps_buf, "\n      }");
  }

  if (fraction) {
    buf_append(&g_steps_buf, ",\n      \"fraction_of_totals\": {\n");
    buf_append(&g_steps_buf, "        \"x\": "); buf_print_float(&g_steps_buf, fraction[0]);
    buf_append(&g_steps_buf, ", \"y\": "); buf_print_float(&g_steps_buf, fraction[1]);
    buf_append(&g_steps_buf, ", \"z\": "); buf_print_float(&g_steps_buf, fraction[2]);
    buf_append(&g_steps_buf, ",\n        \"rx\": "); buf_print_float(&g_steps_buf, fraction[3]);
    buf_append(&g_steps_buf, ", \"ry\": "); buf_print_float(&g_steps_buf, fraction[4]);
    buf_append(&g_steps_buf, ", \"rz\": "); buf_print_float(&g_steps_buf, fraction[5]);
    buf_append(&g_steps_buf, "\n      }");
  }
}

void FORTRAN(json_export_modal_mass_f, (ITG *nev, double *part, double *toteffmass, double *effmodmass, double *fraction)){
  json_export_modal_mass(*nev, part, toteffmass, effmodmass, fraction);
}

void json_export_buckling(double *d, ITG nev) {
  if (!g_json_active || !g_current_step_open || !d || nev <= 0) return;

  buf_append(&g_steps_buf, ",\n      \"buckling_modes\": [\n");
  for (ITG j = 0; j < nev; j++) {
    if (j > 0) buf_append(&g_steps_buf, ",\n");
    buf_printf(&g_steps_buf, "        {\n");
    buf_printf(&g_steps_buf, "          \"mode_number\": %d,\n", (int)(j + 1));
    buf_append(&g_steps_buf, "          \"buckling_factor\": ");
    buf_print_float(&g_steps_buf, d[j]);
    buf_append(&g_steps_buf, "\n        }");
  }
  buf_append(&g_steps_buf, "\n      ]");
  g_has_buckling = 1;
}

static void clean_name(char *dst, const char *src, size_t maxlen) {
  size_t i = 0;
  while (i < maxlen - 1 && src[i] && src[i] != ' ') {
    dst[i] = src[i];
    i++;
  }
  dst[i] = '\0';
}

void json_export_results(double *v, double *fn, double *stx, double *stn,
                         double *een, double *ener, double *energy,
                         char *prlab, char *prset, ITG nprint,
                         char *set, ITG nset, ITG *istartset, ITG *iendset, ITG *ialset,
                         ITG *ipkon, ITG *kon, char *lakon, ITG nk, ITG ne,
                         ITG *mi, double time, double ttime, ITG iinc) {
  if (!g_json_active || !g_current_step_open || nprint <= 0) return;

  ITG mt = mi[1] + 1;

  if (g_current_inc_open && g_last_iinc != iinc) {
    buf_append(&g_steps_buf, "\n        }");
    g_current_inc_open = 0;
  }

  if (!g_current_inc_open) {
    if (g_step_has_increments) {
      buf_append(&g_steps_buf, ",\n        {\n");
    } else {
      buf_append(&g_steps_buf, ",\n      \"increments\": [\n        {\n");
      g_step_has_increments = 1;
    }
    buf_printf(&g_steps_buf, "          \"increment_number\": %d,\n", (int)iinc);
    buf_append(&g_steps_buf, "          \"step_time\": "); buf_print_float(&g_steps_buf, time); buf_append(&g_steps_buf, ",\n");
    buf_append(&g_steps_buf, "          \"total_time\": "); buf_print_float(&g_steps_buf, ttime);
    g_current_inc_open = 1;
    g_last_iinc = iinc;
  }

  int has_node_obj = 0;
  int has_elem_obj = 0;

  for (ITG i = 0; i < nprint; i++) {
    char label[8], setname[88];
    clean_name(label, &prlab[i * 6], 6);
    clean_name(setname, &prset[i * 81], 81);

    ITG iset = -1;
    for (ITG s = 0; s < nset; s++) {
      char sname[88];
      clean_name(sname, &set[s * 81], 81);
      if (strcmp(sname, setname) == 0) {
        iset = s;
        break;
      }
    }

    if (iset < 0 && strcmp(setname, "NALL") != 0 && strcmp(setname, "NALLN") != 0 &&
        strcmp(setname, "EALL") != 0 && strcmp(setname, "EALLE") != 0) {
      continue;
    }

    /* Check for Nodal Output (U, RF, NT, HGN, etc.) */
    if (strcmp(label, "U") == 0 || strcmp(label, "RF") == 0 ||
        strcmp(label, "NT") == 0 || strcmp(label, "HGN") == 0) {
      if (!has_node_obj) {
        buf_append(&g_steps_buf, ",\n          \"node_sets\": {\n");
        has_node_obj = 1;
      } else {
        buf_append(&g_steps_buf, ",\n");
      }

      buf_printf(&g_steps_buf, "            \"%s_%s\": {\n", setname, label);
      buf_printf(&g_steps_buf, "              \"set\": \"%s\",\n", setname);
      buf_printf(&g_steps_buf, "              \"field\": \"%s\",\n", label);
      buf_append(&g_steps_buf, "              \"nodes\": [");

      ITG start = (iset >= 0) ? istartset[iset] - 1 : 0;
      ITG end = (iset >= 0) ? iendset[iset] : nk;
      int is_all = (iset < 0);

      int node_count = 0;
      for (ITG k = start; k < end; k++) {
        ITG node = is_all ? (k + 1) : ialset[k];
        if (node <= 0 || node > nk) continue;
        if (node_count > 0) buf_append(&g_steps_buf, ", ");
        buf_printf(&g_steps_buf, "%d", (int)node);
        node_count++;
      }
      buf_append(&g_steps_buf, "],\n");

      if (strcmp(label, "U") == 0 && v) {
        buf_append(&g_steps_buf, "              \"components\": [\"u1\", \"u2\", \"u3\"],\n");
        buf_append(&g_steps_buf, "              \"values\": [\n");
        int row_count = 0;
        for (ITG k = start; k < end; k++) {
          ITG node = is_all ? (k + 1) : ialset[k];
          if (node <= 0 || node > nk) continue;
          if (row_count > 0) buf_append(&g_steps_buf, ",\n");
          buf_append(&g_steps_buf, "                [");
          buf_print_float(&g_steps_buf, v[mt * (node - 1) + 1]); buf_append(&g_steps_buf, ", ");
          buf_print_float(&g_steps_buf, v[mt * (node - 1) + 2]); buf_append(&g_steps_buf, ", ");
          buf_print_float(&g_steps_buf, v[mt * (node - 1) + 3]);
          buf_append(&g_steps_buf, "]");
          row_count++;
        }
        buf_append(&g_steps_buf, "\n              ]\n");
      } else if (strcmp(label, "RF") == 0 && fn) {
        buf_append(&g_steps_buf, "              \"components\": [\"fx\", \"fy\", \"fz\"],\n");
        buf_append(&g_steps_buf, "              \"values\": [\n");
        double rftot[3] = {0.0, 0.0, 0.0};
        int row_count = 0;
        for (ITG k = start; k < end; k++) {
          ITG node = is_all ? (k + 1) : ialset[k];
          if (node <= 0 || node > nk) continue;
          if (row_count > 0) buf_append(&g_steps_buf, ",\n");
          double fx = fn[mt * (node - 1) + 1];
          double fy = fn[mt * (node - 1) + 2];
          double fz = fn[mt * (node - 1) + 3];
          rftot[0] += fx; rftot[1] += fy; rftot[2] += fz;
          buf_append(&g_steps_buf, "                [");
          buf_print_float(&g_steps_buf, fx); buf_append(&g_steps_buf, ", ");
          buf_print_float(&g_steps_buf, fy); buf_append(&g_steps_buf, ", ");
          buf_print_float(&g_steps_buf, fz);
          buf_append(&g_steps_buf, "]");
          row_count++;
        }
        buf_append(&g_steps_buf, "\n              ],\n");
        buf_append(&g_steps_buf, "              \"total\": [");
        buf_print_float(&g_steps_buf, rftot[0]); buf_append(&g_steps_buf, ", ");
        buf_print_float(&g_steps_buf, rftot[1]); buf_append(&g_steps_buf, ", ");
        buf_print_float(&g_steps_buf, rftot[2]);
        buf_append(&g_steps_buf, "]\n");
      } else if ((strcmp(label, "NT") == 0 || strcmp(label, "HGN") == 0) && v) {
        buf_printf(&g_steps_buf, "              \"components\": [\"%s\"],\n", label);
        buf_append(&g_steps_buf, "              \"values\": [\n");
        int row_count = 0;
        for (ITG k = start; k < end; k++) {
          ITG node = is_all ? (k + 1) : ialset[k];
          if (node <= 0 || node > nk) continue;
          if (row_count > 0) buf_append(&g_steps_buf, ",\n");
          buf_append(&g_steps_buf, "                [");
          buf_print_float(&g_steps_buf, v[mt * (node - 1)]);
          buf_append(&g_steps_buf, "]");
          row_count++;
        }
        buf_append(&g_steps_buf, "\n              ]\n");
      }

      buf_append(&g_steps_buf, "            }");
    }
    /* Check for Element Output (S, E, ENER) */
    else if (strcmp(label, "S") == 0 && stx) {
      if (!has_elem_obj) {
        if (has_node_obj) buf_append(&g_steps_buf, "\n          }");
        buf_append(&g_steps_buf, ",\n          \"element_sets\": {\n");
        has_elem_obj = 1;
      } else {
        buf_append(&g_steps_buf, ",\n");
      }

      buf_printf(&g_steps_buf, "            \"%s_%s\": {\n", setname, label);
      buf_printf(&g_steps_buf, "              \"set\": \"%s\",\n", setname);
      buf_printf(&g_steps_buf, "              \"field\": \"%s\",\n", label);
      buf_append(&g_steps_buf, "              \"components\": [\"sxx\", \"syy\", \"szz\", \"sxy\", \"syz\", \"szx\"],\n");
      buf_append(&g_steps_buf, "              \"values\": [\n");

      ITG start = (iset >= 0) ? istartset[iset] - 1 : 0;
      ITG end = (iset >= 0) ? iendset[iset] : ne;
      int is_all = (iset < 0);

      int elem_count = 0;
      for (ITG k = start; k < end; k++) {
        ITG elem = is_all ? (k + 1) : ialset[k];
        if (elem <= 0 || elem > ne) continue;
        if (elem_count > 0) buf_append(&g_steps_buf, ",\n");

        ITG idx = 6 * mi[0] * (elem - 1);
        buf_printf(&g_steps_buf, "                {\"element\": %d, \"s\": [", (int)elem);
        buf_print_float(&g_steps_buf, stx[idx]); buf_append(&g_steps_buf, ", ");
        buf_print_float(&g_steps_buf, stx[idx+1]); buf_append(&g_steps_buf, ", ");
        buf_print_float(&g_steps_buf, stx[idx+2]); buf_append(&g_steps_buf, ", ");
        buf_print_float(&g_steps_buf, stx[idx+3]); buf_append(&g_steps_buf, ", ");
        buf_print_float(&g_steps_buf, stx[idx+4]); buf_append(&g_steps_buf, ", ");
        buf_print_float(&g_steps_buf, stx[idx+5]);
        buf_append(&g_steps_buf, "]}");
        elem_count++;
      }
      buf_append(&g_steps_buf, "\n              ]\n            }");
    }
  }

  if (has_elem_obj) {
    buf_append(&g_steps_buf, "\n          }");
  } else if (has_node_obj) {
    buf_append(&g_steps_buf, "\n          }");
  }

  /* Total energy balance if available */
  if (energy && (energy[0] != 0.0 || energy[1] != 0.0 || energy[2] != 0.0 || energy[3] != 0.0)) {
    buf_append(&g_steps_buf, ",\n          \"energy\": {\n");
    buf_append(&g_steps_buf, "            \"kinetic\": "); buf_print_float(&g_steps_buf, energy[0]);
    buf_append(&g_steps_buf, ",\n            \"internal\": "); buf_print_float(&g_steps_buf, energy[1]);
    buf_append(&g_steps_buf, ",\n            \"contact_friction\": "); buf_print_float(&g_steps_buf, energy[2]);
    buf_append(&g_steps_buf, ",\n            \"total\": "); buf_print_float(&g_steps_buf, energy[3]);
    buf_append(&g_steps_buf, "\n          }");
  }
}

void json_finalize(int exit_code, double total_time) {
  if (!g_json_active || !g_jobname[0]) return;

  /* Close any open step */
  if (g_current_step_open) {
    json_end_step(g_step_count);
  }

  char filename[512];
  snprintf(filename, sizeof(filename), "%s.json", g_jobname);

  FILE *fp = fopen(filename, "w");
  if (!fp) {
    fprintf(stderr, " *WARNING in json_finalize: unable to open %s for writing\n", filename);
    buf_free(&g_steps_buf);
    return;
  }

  /* Write Full JSON structure */
  fprintf(fp, "{\n");
  fprintf(fp, "  \"meta\": {\n");
  fprintf(fp, "    \"jobname\": \"%s\",\n", g_jobname);
  fprintf(fp, "    \"ccx_version\": \"2.21-multisolver\",\n");
  fprintf(fp, "    \"solver\": \"%s\",\n", g_solver_name);
  fprintf(fp, "    \"num_threads\": %d,\n", (int)g_num_cpus);
  fprintf(fp, "    \"success\": %s,\n", (exit_code == 0) ? "true" : "false");
  fprintf(fp, "    \"exit_code\": %d,\n", exit_code);
  fprintf(fp, "    \"timings\": {\n");
  fprintf(fp, "      \"total_wall_time_s\": %.6f\n", total_time);
  fprintf(fp, "    },\n");
  fprintf(fp, "    \"mesh_statistics\": {\n");
  fprintf(fp, "      \"nodes\": %d,\n", (int)g_num_nodes);
  fprintf(fp, "      \"elements\": %d,\n", (int)g_num_elements);
  fprintf(fp, "      \"equations\": %d\n", (int)g_num_equations);
  fprintf(fp, "    }\n");
  fprintf(fp, "  },\n");

  fprintf(fp, "  \"steps\": [\n");
  if (g_steps_buf.data && g_steps_buf.size > 0) {
    fprintf(fp, "%s\n", g_steps_buf.data);
  }
  fprintf(fp, "  ]\n");
  fprintf(fp, "}\n");

  fclose(fp);
  buf_free(&g_steps_buf);
  printf(" [JSON] Exported results to %s\n", filename);
}

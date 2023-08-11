#ifndef QUICER_NIF_STATIC_H_
#define QUICER_NIF_STATIC_H_

#ifndef QUICER_NIF_VSN
#define QUICER_NIF_VSN 0
#endif

#define MAX_LEN_LIB_VERSION 64

// Bump this when the static data structure changes
#define QUICER_NIF_SDATA_LATEST_VSN 0

typedef struct quicer_nif_sdata_vsn_0
{
  /*
  ** semantic versioning
  ** major, minor, patch, reserved
  */
  char lib_version[MAX_LEN_LIB_VERSION];
  char msquic_git_hash[64];
  uint16_t nif_vsn;
} quicer_nif_sdata_vsn_0;

/*
** NIF Static data
**
*/
typedef union quicer_nif_sdata
{
  quicer_nif_sdata_vsn_0 vsn_0;
} QUICER_NIF_SDATA;

/*
** NIF Static data type, versioned
**
*/
typedef enum quicer_nif_sdata_t
{
  QUICER_NIF_SDATA_VSN_0 = 0
} QUICER_NIF_SDATA_t;

/*
** NIF Private Static Data
*/
typedef struct quicer_nif_psd
{
  QUICER_NIF_SDATA_t type;
  QUICER_NIF_SDATA data;
} QUICER_NIF_PSD;

/*
 * New PSD with latest version
 * */
QUICER_NIF_PSD *
quicer_psd_new_latest()
{
  QUICER_NIF_PSD *psd = (QUICER_NIF_PSD *)malloc(sizeof(QUICER_NIF_PSD));

  if (psd == NULL)
    return NULL;

  psd->type = QUICER_NIF_SDATA_LATEST_VSN;

  switch (psd->type)
    {
    case QUICER_NIF_SDATA_VSN_0:
    default:
      memset(&psd->data.vsn_0, 0, sizeof(quicer_nif_sdata_vsn_0));
      psd->data.vsn_0.nif_vsn = QUICER_NIF_VSN;
      break;
    }
  return psd;
}

/*
**
*/
static BOOLEAN
load_priv_data(ErlNifEnv *env, ERL_NIF_TERM loadinfo, void **priv_data)
{
  QUICER_NIF_PSD *psd = quicer_psd_new_latest();
  switch (psd->type)
    {
    case QUICER_NIF_SDATA_VSN_0:
    default:
      if (0 > enif_get_string(env,
                              loadinfo,
                              psd->data.vsn_0.lib_version,
                              MAX_LEN_LIB_VERSION,
                              ERL_NIF_LATIN1))
        {
          free(psd);
          *priv_data = NULL;
          return FALSE;
        }
      *priv_data = psd;
      break;
    }
  return TRUE;
}

void
get_lib_vsn_from_psd(QUICER_NIF_PSD *psd, char **vsn)
{
  switch (psd->type)
    {
    case QUICER_NIF_SDATA_VSN_0:
    default:
      *vsn = psd->data.vsn_0.lib_version;
    }
}

void
get_nif_vsn_from_psd(QUICER_NIF_PSD *psd, uint8_t *vsn)
{
  switch (psd->type)
    {
    case QUICER_NIF_SDATA_VSN_0:
    default:
      *vsn = psd->data.vsn_0.nif_vsn;
    }
}

#endif // QUICER_NIF_STATIC_H_

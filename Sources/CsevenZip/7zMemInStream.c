/* 7zMemInStream.c -- ISeekInStream over a caller-owned memory buffer
SPDX-FileCopyrightText: 2026 qoo
SPDX-License-Identifier: MIT */

#include "Precomp.h"

#include <string.h>

#include "7zMemInStream.h"

static SRes MemInStream_Read(ISeekInStreamPtr pp, void *buf, size_t *size)
{
  CMemInStream *p = Z7_CONTAINER_FROM_VTBL(pp, CMemInStream, vt);
  size_t n = *size;
  const size_t remaining = p->pos < p->size ? p->size - p->pos : 0;
  if (n > remaining)
    n = remaining;
  if (n != 0)
    memcpy(buf, p->data + p->pos, n);
  p->pos += n;
  *size = n;
  return SZ_OK;
}

static SRes MemInStream_Seek(ISeekInStreamPtr pp, Int64 *pos, ESzSeek origin)
{
  CMemInStream *p = Z7_CONTAINER_FROM_VTBL(pp, CMemInStream, vt);
  Int64 target;
  switch (origin)
  {
    case SZ_SEEK_SET: target = *pos; break;
    case SZ_SEEK_CUR: target = (Int64)p->pos + *pos; break;
    case SZ_SEEK_END: target = (Int64)p->size + *pos; break;
    default: return SZ_ERROR_PARAM;
  }
  if (target < 0)
    return SZ_ERROR_PARAM;
  /* Like lseek, seeking past the end is allowed; reads there return 0 bytes. */
  p->pos = (size_t)target;
  *pos = target;
  return SZ_OK;
}

void MemInStream_Init(CMemInStream *p, const void *data, size_t size)
{
  p->vt.Read = MemInStream_Read;
  p->vt.Seek = MemInStream_Seek;
  p->data = (const Byte *)data;
  p->size = size;
  p->pos = 0;
}

/* 7zMemInStream.h -- ISeekInStream over a caller-owned memory buffer
SPDX-FileCopyrightText: 2026 qoo
SPDX-License-Identifier: MIT

Lets SzArEx_Open / SzArEx_Extract / SzFolderStream read an archive that is held in
memory instead of a file, so nested archives need not be written to disk first.
The buffer is not copied and must outlive the stream. */

#ifndef ZIP7_INC_7Z_MEM_IN_STREAM_H
#define ZIP7_INC_7Z_MEM_IN_STREAM_H

#include "7zTypes.h"

EXTERN_C_BEGIN

typedef struct
{
  ISeekInStream vt;
  const Byte *data;
  size_t size;
  size_t pos;
} CMemInStream;

void MemInStream_Init(CMemInStream *p, const void *data, size_t size);

EXTERN_C_END

#endif

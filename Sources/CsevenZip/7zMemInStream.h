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

/* ISeekInStream over a caller-supplied positional reader (`Archive(reader:)`).
   `read(ctx, offset, buf, size)` returns the number of bytes it put in `buf`
   (0 at or past the end, -1 on an error, which becomes SZ_ERROR_READ). */
typedef Int64 (*CallbackInStreamRead)(void *ctx, Int64 offset, void *buf, size_t size);
typedef struct
{
  ISeekInStream vt;
  void *ctx;
  CallbackInStreamRead read;
  Int64 size;
  Int64 pos;
} CCallbackInStream;

void CallbackInStream_Init(CCallbackInStream *p, void *ctx, CallbackInStreamRead read, Int64 size);

EXTERN_C_END

#endif

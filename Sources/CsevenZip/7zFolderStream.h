/* 7zFolderStream.h -- Streaming (pull-based) decoder for one 7z folder (solid block)
SPDX-FileCopyrightText: 2026 qoo
SPDX-License-Identifier: MIT

`SzArEx_Extract` (7zDec.c) decodes a whole folder into one buffer, so reading a single
file out of a solid block costs the memory of the entire block. This decoder instead
produces the folder's unpacked bytes on demand: the caller pulls as many bytes as it
wants, memory stays bounded by the decoder state (dictionary) plus small buffers, and
reading the files of a solid block in order costs one decode of the block in total.

Supported coder chains (the same set 7zDec.c handles, minus BCJ2):
  - Copy / LZMA / LZMA2 / PPMd
  - one of those, followed by a branch filter (BCJ x86, PPC, IA64, ARM, ARMT, SPARC,
    ARM64, RISC-V) or Delta
Anything else (BCJ2, BZip2, Deflate, AES, ...) makes `SzFolderStream_Create` return
SZ_ERROR_UNSUPPORTED; the caller is expected to fall back to `SzArEx_Extract`.

The folder CRC (when the archive stores one) is verified once the stream has been read
through to its end, because every byte -- including skipped ones -- passes through
`SzFolderStream_Read`. */

#ifndef ZIP7_INC_7Z_FOLDER_STREAM_H
#define ZIP7_INC_7Z_FOLDER_STREAM_H

#include "7z.h"

EXTERN_C_BEGIN

typedef struct CSzFolderStream_ CSzFolderStream;

/* Creates a decoder positioned at the start of the folder's unpacked data.
   `inStream` is the archive file; it is seeked before every read, so it may be shared
   with other readers (e.g. `SzArEx_Extract`) as long as they are not used concurrently.
   `inStream` is not copied and must outlive the returned object. */
SRes SzFolderStream_Create(CSzFolderStream **result,
    const CSzArEx *db,
    ISeekInStreamPtr inStream,
    UInt32 folderIndex,
    ISzAllocPtr alloc);

/* Produces up to *size bytes into dest. On return *size is the number of bytes
   produced; it is 0 only when the folder's unpacked data has been exhausted. */
SRes SzFolderStream_Read(CSzFolderStream *p, Byte *dest, size_t *size);

/* Decodes and discards `size` bytes. Fails with SZ_ERROR_INPUT_EOF when the folder
   ends first. */
SRes SzFolderStream_Skip(CSzFolderStream *p, UInt64 size);

/* Current position in the folder's unpacked data (bytes produced so far). */
UInt64 SzFolderStream_GetPosition(const CSzFolderStream *p);

/* Total unpacked size of the folder. */
UInt64 SzFolderStream_GetUnpackSize(const CSzFolderStream *p);

void SzFolderStream_Free(CSzFolderStream *p);

EXTERN_C_END

#endif

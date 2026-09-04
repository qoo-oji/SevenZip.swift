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
`SzFolderStream_Read`.

Moving backwards: a solid block is one stream, so in general an earlier position can only
be reached by decoding the block again from its start. Two cases are cheaper and handled
by `SzFolderStream_SeekBack`: a Copy block is the pack stream itself (the input is simply
re-positioned), and for LZMA / LZMA2 without a branch filter the decoder's dictionary
already holds the most recent `dicSize` bytes of output, which are handed out again
without decoding ("replay"). `SzFolderStream_CanSeekBack` tells whether a position is
reachable that way; otherwise the caller creates a new stream. */

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

/* Current read position in the folder's unpacked data (the offset of the next byte
   `SzFolderStream_Read` returns). After `SzFolderStream_SeekBack` this is behind the
   decoder, and reads are served from the dictionary until the two meet again. */
UInt64 SzFolderStream_GetPosition(const CSzFolderStream *p);

/* Whether `position` (<= the current read position) can be reached without decoding the
   block again: always for a Copy block; within the dictionary for LZMA / LZMA2 without a
   filter (see the header comment). Never for PPMd or filtered blocks. */
BoolInt SzFolderStream_CanSeekBack(const CSzFolderStream *p, UInt64 position);

/* Moves the read position back to `position`. Fails with SZ_ERROR_PARAM when
   `SzFolderStream_CanSeekBack` is false. The folder CRC keeps being verified: bytes are
   only added to the running CRC the first time they are decoded. */
SRes SzFolderStream_SeekBack(CSzFolderStream *p, UInt64 position);

/* Memory held by this stream: the decoder state (LZMA dictionary + probabilities, or the
   PPMd model) and the input / filter / skip buffers. */
size_t SzFolderStream_GetResidentBytes(const CSzFolderStream *p);

/* Total unpacked size of the folder. */
UInt64 SzFolderStream_GetUnpackSize(const CSzFolderStream *p);

void SzFolderStream_Free(CSzFolderStream *p);

EXTERN_C_END

#endif

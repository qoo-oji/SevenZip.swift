/* 7zFolderStream.c -- Streaming (pull-based) decoder for one 7z folder (solid block)
SPDX-FileCopyrightText: 2026 qoo
SPDX-License-Identifier: MIT

The coder-chain handling mirrors SzFolder_Decode2 in 7zDec.c (public domain, Igor Pavlov);
the difference is that the main coder is driven incrementally through the *_DecodeToBuf /
DecodeSymbol APIs and the branch filter is applied chunk by chunk, carrying the filter's
look-ahead bytes over to the next chunk. See 7zFolderStream.h for the contract. */

#include "Precomp.h"

#include <string.h>

#include "7zFolderStream.h"
#include "7zCrc.h"
#include "Bra.h"
#include "CpuArch.h"
#include "Delta.h"
#include "LzmaDec.h"
#include "Lzma2Dec.h"
#include "Ppmd7.h"

#define k_Copy  0
#define k_Delta 3
#define k_ARM64 0xa
#define k_RISCV 0xb
#define k_LZMA2 0x21
#define k_LZMA  0x30101
#define k_PPMD  0x30401
#define k_BCJ   0x3030103
#define k_PPC   0x3030205
#define k_IA64  0x3030401
#define k_ARM   0x3030501
#define k_ARMT  0x3030701
#define k_SPARC 0x3030805

/* Packed input fetched from the archive file per fill. */
#define IN_BUF_SIZE (1 << 18)
/* Main-coder output held for filtering. Must exceed the largest filter look-ahead
   (16 bytes for IA64) by a wide margin so every fill makes progress. */
#define FILTER_BUF_SIZE (1 << 18)
/* Scratch for SzFolderStream_Skip. */
#define SKIP_BUF_SIZE (1 << 16)

enum
{
  MAIN_COPY,
  MAIN_LZMA,
  MAIN_LZMA2,
  MAIN_PPMD
};

struct CSzFolderStream_;

/* IByteIn adapter that feeds the PPMd range decoder from the input buffer. */
typedef struct
{
  IByteIn vt;
  struct CSzFolderStream_ *owner;
} CPpmdByteIn;

struct CSzFolderStream_
{
  /* Copied by value: the caller's ISzAlloc may live in memory that is only valid
     during the SzFolderStream_Create call (e.g. Swift's inout `&allocator`). */
  ISzAlloc allocStorage;
  ISzAllocPtr alloc;
  ISeekInStreamPtr inStream;

  /* --- packed input (exactly one pack stream for the supported chains) --- */
  UInt64 packPos;   /* absolute file offset of the next byte to fetch into inBuf */
  UInt64 packEnd;   /* absolute file offset one past the pack stream */
  Byte *inBuf;
  size_t inPos;     /* inBuf[inPos, inSize) is unread input */
  size_t inSize;
  BoolInt inExtra;  /* PPMd byte reader ran past the end of the pack stream */
  SRes inRes;       /* first error hit by the PPMd byte reader */

  /* --- main coder --- */
  int mainKind;
  CLzmaDec lzma;
  CLzma2Dec lzma2;
  CPpmd7 ppmd;
  CPpmdByteIn ppmdIn;
  BoolInt ppmdRangeInited;
  UInt64 mainUnpackSize;
  UInt64 mainProduced;

  /* --- optional branch/delta filter applied to the main coder's output --- */
  UInt32 filterMethod;  /* 0 when there is no filter */
  unsigned delta;
  Byte deltaState[DELTA_STATE_SIZE];
  UInt32 x86State;
  UInt32 pc;            /* virtual program counter of filtBuf[0] */
  Byte *filtBuf;
  size_t readyPos;      /* filtBuf[readyPos, readyEnd) is filtered output not yet handed out */
  size_t readyEnd;
  size_t pendingPos;    /* filtBuf[pendingPos, pendingEnd) is the filter's unprocessed tail */
  size_t pendingEnd;

  /* --- folder output --- */
  UInt64 unpackSize;
  UInt64 position;
  BoolInt hasCrc;
  UInt32 expectedCrc;
  UInt32 crc;

  Byte *skipBuf;
};


/* ---- packed input ---- */

/* Makes sure inBuf[inPos, inSize) is non-empty unless the pack stream is exhausted. */
static SRes FillInput(CSzFolderStream *p)
{
  size_t size;
  Int64 pos;
  if (p->inPos < p->inSize)
    return SZ_OK;
  p->inPos = p->inSize = 0;
  if (p->packPos >= p->packEnd)
    return SZ_OK;
  pos = (Int64)p->packPos;
  RINOK(ISeekInStream_Seek(p->inStream, &pos, SZ_SEEK_SET))
  size = IN_BUF_SIZE;
  if ((UInt64)size > p->packEnd - p->packPos)
    size = (size_t)(p->packEnd - p->packPos);
  RINOK(ISeekInStream_Read(p->inStream, p->inBuf, &size))
  if (size == 0)
    return SZ_ERROR_INPUT_EOF;
  p->packPos += size;
  p->inSize = size;
  return SZ_OK;
}

static Byte PpmdByteIn_Read(IByteInPtr pp)
{
  CPpmdByteIn *in = Z7_CONTAINER_FROM_VTBL(pp, CPpmdByteIn, vt);
  CSzFolderStream *p = in->owner;
  if (p->inPos == p->inSize && p->inRes == SZ_OK)
    p->inRes = FillInput(p);
  if (p->inPos < p->inSize)
    return p->inBuf[p->inPos++];
  p->inExtra = True;
  return 0;
}


/* ---- main coder ---- */

/* Produces up to *size bytes of the main coder's output. *size becomes 0 only at the
   end of the main coder's data. */
static SRes DecodeMain(CSzFolderStream *p, Byte *dest, size_t *size)
{
  size_t want = *size;
  size_t produced = 0;
  const UInt64 remaining = p->mainUnpackSize - p->mainProduced;
  if ((UInt64)want > remaining)
    want = (size_t)remaining;
  *size = 0;
  if (want == 0)
    return SZ_OK;

  switch (p->mainKind)
  {
    case MAIN_COPY:
      while (produced < want)
      {
        size_t n;
        RINOK(FillInput(p))
        n = p->inSize - p->inPos;
        if (n == 0)
          return SZ_ERROR_INPUT_EOF;
        if (n > want - produced)
          n = want - produced;
        memcpy(dest + produced, p->inBuf + p->inPos, n);
        p->inPos += n;
        produced += n;
      }
      break;

    case MAIN_LZMA:
    case MAIN_LZMA2:
      while (produced < want)
      {
        SizeT destLen = want - produced;
        SizeT srcLen;
        ELzmaStatus status;
        /* LZMA_FINISH_END is only allowed when this call reaches the end of the block. */
        const ELzmaFinishMode finishMode =
            ((UInt64)(produced + destLen) == remaining) ? LZMA_FINISH_END : LZMA_FINISH_ANY;
        SRes res;
        RINOK(FillInput(p))
        srcLen = p->inSize - p->inPos;
        if (p->mainKind == MAIN_LZMA)
          res = LzmaDec_DecodeToBuf(&p->lzma, dest + produced, &destLen,
              p->inBuf + p->inPos, &srcLen, finishMode, &status);
        else
          res = Lzma2Dec_DecodeToBuf(&p->lzma2, dest + produced, &destLen,
              p->inBuf + p->inPos, &srcLen, finishMode, &status);
        p->inPos += srcLen;
        produced += destLen;
        if (res != SZ_OK)
          return res;
        if (status == LZMA_STATUS_FINISHED_WITH_MARK)
        {
          if (p->mainProduced + produced != p->mainUnpackSize)
            return SZ_ERROR_DATA;
          break;
        }
        if (produced < want)
        {
          if (status == LZMA_STATUS_NEEDS_MORE_INPUT && p->inPos == p->inSize && p->packPos >= p->packEnd)
            return SZ_ERROR_INPUT_EOF;
          if (srcLen == 0 && destLen == 0)
            return SZ_ERROR_DATA; /* no progress: corrupt stream */
        }
      }
      break;

    case MAIN_PPMD:
      if (!p->ppmdRangeInited)
      {
        if (!Ppmd7z_RangeDec_Init(&p->ppmd.rc.dec))
          return SZ_ERROR_DATA;
        if (p->inExtra)
          return (p->inRes != SZ_OK ? p->inRes : SZ_ERROR_DATA);
        p->ppmdRangeInited = True;
      }
      while (produced < want)
      {
        const int sym = Ppmd7z_DecodeSymbol(&p->ppmd);
        if (p->inExtra)
          return (p->inRes != SZ_OK ? p->inRes : SZ_ERROR_DATA);
        if (sym < 0)
          return SZ_ERROR_DATA;
        dest[produced++] = (Byte)sym;
      }
      if (p->mainProduced + produced == p->mainUnpackSize
          && !Ppmd7z_RangeDec_IsFinishedOK(&p->ppmd.rc.dec))
        return SZ_ERROR_DATA;
      break;

    default:
      return SZ_ERROR_UNSUPPORTED;
  }

  p->mainProduced += produced;
  *size = produced;
  return SZ_OK;
}


/* ---- filter ---- */

/* Refills filtBuf: moves the unprocessed tail to the front, appends fresh main-coder
   output, runs the filter, and exposes the processed prefix as ready bytes. */
static SRes FillFilter(CSzFolderStream *p)
{
  size_t total, fresh;
  Byte *buf = p->filtBuf;
  Byte *stop;

  const size_t pending = p->pendingEnd - p->pendingPos;
  if (pending != 0 && p->pendingPos != 0)
    memmove(buf, buf + p->pendingPos, pending);
  p->pendingPos = 0;
  p->pendingEnd = pending;
  p->readyPos = p->readyEnd = 0;

  fresh = FILTER_BUF_SIZE - pending;
  RINOK(DecodeMain(p, buf + pending, &fresh))
  total = pending + fresh;

  if (fresh == 0)
  {
    /* End of the main coder: whatever the filter left unprocessed is passed through. */
    p->readyEnd = total;
    p->pendingPos = p->pendingEnd = 0;
    return SZ_OK;
  }

  switch (p->filterMethod)
  {
    case k_Delta:
      Delta_Decode(p->deltaState, p->delta, buf, total);
      stop = buf + total;
      break;
    case k_BCJ:   stop = z7_BranchConvSt_X86_Dec(buf, total, p->pc, &p->x86State); break;
    case k_PPC:   stop = z7_BranchConv_PPC_Dec(buf, total, p->pc); break;
    case k_IA64:  stop = z7_BranchConv_IA64_Dec(buf, total, p->pc); break;
    case k_ARM:   stop = z7_BranchConv_ARM_Dec(buf, total, p->pc); break;
    case k_ARMT:  stop = z7_BranchConv_ARMT_Dec(buf, total, p->pc); break;
    case k_SPARC: stop = z7_BranchConv_SPARC_Dec(buf, total, p->pc); break;
    case k_ARM64: stop = z7_BranchConv_ARM64_Dec(buf, total, p->pc); break;
    case k_RISCV: stop = z7_BranchConv_RISCV_Dec(buf, total, p->pc); break;
    default:
      return SZ_ERROR_UNSUPPORTED;
  }

  {
    const size_t processed = (size_t)(stop - buf);
    p->pc += (UInt32)processed;
    p->readyEnd = processed;
    p->pendingPos = processed;
    p->pendingEnd = total;
  }
  return SZ_OK;
}


/* ---- public API ---- */

SRes SzFolderStream_Read(CSzFolderStream *p, Byte *dest, size_t *size)
{
  size_t want = *size;
  size_t produced = 0;
  const UInt64 remaining = p->unpackSize - p->position;
  if ((UInt64)want > remaining)
    want = (size_t)remaining;
  *size = 0;

  while (produced < want)
  {
    if (p->filterMethod == 0)
    {
      size_t n = want - produced;
      RINOK(DecodeMain(p, dest + produced, &n))
      if (n == 0)
        return SZ_ERROR_INPUT_EOF;
      produced += n;
    }
    else
    {
      size_t n = p->readyEnd - p->readyPos;
      if (n == 0)
      {
        RINOK(FillFilter(p))
        n = p->readyEnd - p->readyPos;
        if (n == 0)
          return SZ_ERROR_INPUT_EOF;
      }
      if (n > want - produced)
        n = want - produced;
      memcpy(dest + produced, p->filtBuf + p->readyPos, n);
      p->readyPos += n;
      produced += n;
    }
  }

  if (p->hasCrc && produced != 0)
    p->crc = CrcUpdate(p->crc, dest, produced);
  p->position += produced;
  *size = produced;

  if (p->hasCrc && p->position == p->unpackSize && CRC_GET_DIGEST(p->crc) != p->expectedCrc)
    return SZ_ERROR_CRC;
  return SZ_OK;
}

SRes SzFolderStream_Skip(CSzFolderStream *p, UInt64 size)
{
  if (size > p->unpackSize - p->position)
    return SZ_ERROR_INPUT_EOF;
  if (!p->skipBuf)
  {
    p->skipBuf = (Byte *)ISzAlloc_Alloc(p->alloc, SKIP_BUF_SIZE);
    if (!p->skipBuf)
      return SZ_ERROR_MEM;
  }
  while (size != 0)
  {
    size_t n = SKIP_BUF_SIZE;
    if ((UInt64)n > size)
      n = (size_t)size;
    RINOK(SzFolderStream_Read(p, p->skipBuf, &n))
    if (n == 0)
      return SZ_ERROR_INPUT_EOF;
    size -= n;
  }
  return SZ_OK;
}

UInt64 SzFolderStream_GetPosition(const CSzFolderStream *p) { return p->position; }
UInt64 SzFolderStream_GetUnpackSize(const CSzFolderStream *p) { return p->unpackSize; }

void SzFolderStream_Free(CSzFolderStream *p)
{
  ISzAllocPtr alloc;
  if (!p)
    return;
  alloc = p->alloc;
  switch (p->mainKind)
  {
    case MAIN_LZMA:  LzmaDec_Free(&p->lzma, alloc); break;
    case MAIN_LZMA2: Lzma2Dec_Free(&p->lzma2, alloc); break;
    case MAIN_PPMD:  Ppmd7_Free(&p->ppmd, alloc); break;
    default: break;
  }
  ISzAlloc_Free(alloc, p->inBuf);
  ISzAlloc_Free(alloc, p->filtBuf);
  ISzAlloc_Free(alloc, p->skipBuf);
  ISzAlloc_Free(alloc, p);
}


static BoolInt IsMainMethod(UInt32 m)
{
  return m == k_Copy || m == k_LZMA || m == k_LZMA2 || m == k_PPMD;
}

static BoolInt IsFilterMethod(UInt32 m)
{
  switch (m)
  {
    case k_Delta: case k_BCJ: case k_PPC: case k_IA64: case k_ARM:
    case k_ARMT: case k_SPARC: case k_ARM64: case k_RISCV:
      return True;
    default:
      return False;
  }
}

/* Same shape checks as CheckSupportedFolder in 7zDec.c, without the BCJ2 case. */
static SRes CheckSupportedFolder(const CSzFolder *f)
{
  if (f->NumCoders < 1 || f->NumCoders > 2)
    return SZ_ERROR_UNSUPPORTED;
  if (f->Coders[0].NumStreams != 1 || !IsMainMethod(f->Coders[0].MethodID))
    return SZ_ERROR_UNSUPPORTED;
  if (f->NumPackStreams != 1 || f->PackStreams[0] != 0)
    return SZ_ERROR_UNSUPPORTED;
  if (f->NumCoders == 1)
    return f->NumBonds == 0 ? SZ_OK : SZ_ERROR_UNSUPPORTED;
  {
    const CSzCoderInfo *c = &f->Coders[1];
    if (c->NumStreams != 1
        || f->NumBonds != 1
        || f->Bonds[0].InIndex != 1
        || f->Bonds[0].OutIndex != 0
        || !IsFilterMethod(c->MethodID))
      return SZ_ERROR_UNSUPPORTED;
  }
  return SZ_OK;
}

static SRes InitMain(CSzFolderStream *p, const CSzCoderInfo *coder, const Byte *props, UInt64 packSize)
{
  const unsigned propsSize = coder->PropsSize;
  switch (coder->MethodID)
  {
    case k_Copy:
      if (packSize != p->mainUnpackSize)
        return SZ_ERROR_DATA;
      p->mainKind = MAIN_COPY;
      return SZ_OK;

    case k_LZMA:
      LzmaDec_CONSTRUCT(&p->lzma)
      RINOK(LzmaDec_Allocate(&p->lzma, props, propsSize, p->alloc))
      LzmaDec_Init(&p->lzma);
      p->mainKind = MAIN_LZMA;
      return SZ_OK;

    case k_LZMA2:
      if (propsSize != 1)
        return SZ_ERROR_DATA;
      Lzma2Dec_CONSTRUCT(&p->lzma2)
      RINOK(Lzma2Dec_Allocate(&p->lzma2, props[0], p->alloc))
      Lzma2Dec_Init(&p->lzma2);
      p->mainKind = MAIN_LZMA2;
      return SZ_OK;

    case k_PPMD:
    {
      unsigned order;
      UInt32 memSize;
      if (propsSize != 5)
        return SZ_ERROR_UNSUPPORTED;
      order = props[0];
      memSize = GetUi32(props + 1);
      if (order < PPMD7_MIN_ORDER || order > PPMD7_MAX_ORDER
          || memSize < PPMD7_MIN_MEM_SIZE || memSize > PPMD7_MAX_MEM_SIZE)
        return SZ_ERROR_UNSUPPORTED;
      Ppmd7_Construct(&p->ppmd);
      if (!Ppmd7_Alloc(&p->ppmd, memSize, p->alloc))
        return SZ_ERROR_MEM;
      Ppmd7_Init(&p->ppmd, order);
      p->ppmdIn.vt.Read = PpmdByteIn_Read;
      p->ppmdIn.owner = p;
      p->ppmd.rc.dec.Stream = &p->ppmdIn.vt;
      p->mainKind = MAIN_PPMD;
      return SZ_OK;
    }

    default:
      return SZ_ERROR_UNSUPPORTED;
  }
}

static SRes InitFilter(CSzFolderStream *p, const CSzCoderInfo *coder, const Byte *props)
{
  const unsigned propsSize = coder->PropsSize;
  p->pc = 0;
  switch (coder->MethodID)
  {
    case k_Delta:
      if (propsSize != 1)
        return SZ_ERROR_UNSUPPORTED;
      p->delta = (unsigned)props[0] + 1;
      Delta_Init(p->deltaState);
      break;
    case k_ARM64:
    case k_RISCV:
      if (propsSize == 4)
      {
        p->pc = GetUi32(props);
        if (p->pc & (coder->MethodID == k_ARM64 ? 3 : 1))
          return SZ_ERROR_UNSUPPORTED;
      }
      else if (propsSize != 0)
        return SZ_ERROR_UNSUPPORTED;
      break;
    default:
      if (propsSize != 0)
        return SZ_ERROR_UNSUPPORTED;
      break;
  }
  p->x86State = Z7_BRANCH_CONV_ST_X86_STATE_INIT_VAL;
  p->filterMethod = coder->MethodID;
  p->filtBuf = (Byte *)ISzAlloc_Alloc(p->alloc, FILTER_BUF_SIZE);
  if (!p->filtBuf)
    return SZ_ERROR_MEM;
  return SZ_OK;
}

SRes SzFolderStream_Create(CSzFolderStream **result,
    const CSzArEx *db,
    ISeekInStreamPtr inStream,
    UInt32 folderIndex,
    ISzAllocPtr alloc)
{
  const CSzAr *ar = &db->db;
  CSzFolder folder;
  CSzData sd;
  const Byte *codersData;
  const UInt64 *unpackSizes;
  const UInt64 *packPositions;
  CSzFolderStream *p;
  SRes res;

  *result = NULL;
  if (folderIndex >= ar->NumFolders)
    return SZ_ERROR_PARAM;

  codersData = ar->CodersData + ar->FoCodersOffsets[folderIndex];
  sd.Data = codersData;
  sd.Size = ar->FoCodersOffsets[(size_t)folderIndex + 1] - ar->FoCodersOffsets[folderIndex];
  RINOK(SzGetNextFolderItem(&folder, &sd))
  if (sd.Size != 0 || folder.UnpackStream != ar->FoToMainUnpackSizeIndex[folderIndex])
    return SZ_ERROR_FAIL;
  RINOK(CheckSupportedFolder(&folder))

  unpackSizes = &ar->CoderUnpackSizes[ar->FoToCoderUnpackSizes[folderIndex]];
  packPositions = ar->PackPositions + ar->FoStartPackStreamIndex[folderIndex];

  p = (CSzFolderStream *)ISzAlloc_Alloc(alloc, sizeof(*p));
  if (!p)
    return SZ_ERROR_MEM;
  memset(p, 0, sizeof(*p));
  p->allocStorage = *alloc;
  p->alloc = &p->allocStorage;
  p->inStream = inStream;
  p->unpackSize = SzAr_GetFolderUnpackSize(ar, folderIndex);
  p->mainUnpackSize = unpackSizes[0];
  p->packPos = db->dataPos + packPositions[0];
  p->packEnd = db->dataPos + packPositions[1];
  p->mainKind = -1;
  if (SzBitWithVals_Check(&ar->FolderCRCs, folderIndex))
  {
    p->hasCrc = True;
    p->expectedCrc = ar->FolderCRCs.Vals[folderIndex];
    p->crc = CRC_INIT_VAL;
  }

  res = SZ_OK;
  if (p->mainUnpackSize != p->unpackSize)
    res = SZ_ERROR_DATA; /* filters preserve size; the folder's size must match */
  if (res == SZ_OK)
  {
    p->inBuf = (Byte *)ISzAlloc_Alloc(alloc, IN_BUF_SIZE);
    if (!p->inBuf)
      res = SZ_ERROR_MEM;
  }
  if (res == SZ_OK)
    res = InitMain(p, &folder.Coders[0], codersData + folder.Coders[0].PropsOffset,
        packPositions[1] - packPositions[0]);
  if (res == SZ_OK && folder.NumCoders == 2)
    res = InitFilter(p, &folder.Coders[1], codersData + folder.Coders[1].PropsOffset);

  if (res != SZ_OK)
  {
    SzFolderStream_Free(p);
    return res;
  }
  *result = p;
  return SZ_OK;
}

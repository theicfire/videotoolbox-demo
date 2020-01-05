/*
 *  Copyright (c) 2015 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 *
 */

#include "nalu_rewriter.h"

#include <CoreFoundation/CoreFoundation.h>
#include <memory>
#include <vector>

namespace webrtc {

using H264::kAud;
using H264::kSps;
using H264::NaluIndex;
using H264::NaluType;
using H264::ParseNaluType;

const char kAnnexBHeaderBytes[4] = {0, 0, 0, 1};
const size_t kAvccHeaderByteSize = sizeof(uint32_t);

bool H264AnnexBBufferToCMSampleBuffer(const uint8_t* annexb_buffer,
                                      size_t annexb_buffer_size,
                                      CMVideoFormatDescriptionRef video_format,
                                      CMSampleBufferRef* out_sample_buffer,
                                      CMMemoryPoolRef memory_pool) {
//  RTC_DCHECK(annexb_buffer);
//  RTC_DCHECK(out_sample_buffer);
//  RTC_DCHECK(video_format);
  *out_sample_buffer = nullptr;

  AnnexBBufferReader reader(annexb_buffer, annexb_buffer_size);
  if (reader.SeekToNextNaluOfType(kSps)) {
    // Buffer contains an SPS NALU - skip it and the following PPS
    const uint8_t* data;
    size_t data_len;
    if (!reader.ReadNalu(&data, &data_len)) {
//      RTC_LOG(LS_ERROR) << "Failed to read SPS";
      return false;
    }
    if (!reader.ReadNalu(&data, &data_len)) {
//      RTC_LOG(LS_ERROR) << "Failed to read PPS";
      return false;
    }
  } else {
    // No SPS NALU - start reading from the first NALU in the buffer
    reader.SeekToStart();
  }

  // Allocate memory as a block buffer.
  CMBlockBufferRef block_buffer = nullptr;
  CFAllocatorRef block_allocator = CMMemoryPoolGetAllocator(memory_pool);
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, reader.BytesRemaining(), block_allocator,
      nullptr, 0, reader.BytesRemaining(), kCMBlockBufferAssureMemoryNowFlag,
      &block_buffer);
  if (status != kCMBlockBufferNoErr) {
//    RTC_LOG(LS_ERROR) << "Failed to create block buffer.";
    return false;
  }

  // Make sure block buffer is contiguous.
  CMBlockBufferRef contiguous_buffer = nullptr;
  if (!CMBlockBufferIsRangeContiguous(block_buffer, 0, 0)) {
    status = CMBlockBufferCreateContiguous(kCFAllocatorDefault, block_buffer,
                                           block_allocator, nullptr, 0, 0, 0,
                                           &contiguous_buffer);
    if (status != noErr) {
//      RTC_LOG(LS_ERROR) << "Failed to flatten non-contiguous block buffer: "
//                        << status;
      CFRelease(block_buffer);
      return false;
    }
  } else {
    contiguous_buffer = block_buffer;
    block_buffer = nullptr;
  }

  // Get a raw pointer into allocated memory.
  size_t block_buffer_size = 0;
  char* data_ptr = nullptr;
  status = CMBlockBufferGetDataPointer(contiguous_buffer, 0, nullptr,
                                       &block_buffer_size, &data_ptr);
  if (status != kCMBlockBufferNoErr) {
//    RTC_LOG(LS_ERROR) << "Failed to get block buffer data pointer.";
    CFRelease(contiguous_buffer);
    return false;
  }
//  RTC_DCHECK(block_buffer_size == reader.BytesRemaining());

  // Write Avcc NALUs into block buffer memory.
  AvccBufferWriter writer(reinterpret_cast<uint8_t*>(data_ptr),
                          block_buffer_size);
  while (reader.BytesRemaining() > 0) {
    const uint8_t* nalu_data_ptr = nullptr;
    size_t nalu_data_size = 0;
    if (reader.ReadNalu(&nalu_data_ptr, &nalu_data_size)) {
      writer.WriteNalu(nalu_data_ptr, nalu_data_size);
    }
  }

  // Create sample buffer.
  status = CMSampleBufferCreate(kCFAllocatorDefault, contiguous_buffer, true,
                                nullptr, nullptr, video_format, 1, 0, nullptr,
                                0, nullptr, out_sample_buffer);
  if (status != noErr) {
//    RTC_LOG(LS_ERROR) << "Failed to create sample buffer.";
    CFRelease(contiguous_buffer);
    return false;
  }
  CFRelease(contiguous_buffer);
  return true;
}

CMVideoFormatDescriptionRef CreateVideoFormatDescription(
    const uint8_t* annexb_buffer,
    size_t annexb_buffer_size) {
  const uint8_t* param_set_ptrs[2] = {};
  size_t param_set_sizes[2] = {};
  AnnexBBufferReader reader(annexb_buffer, annexb_buffer_size);
  // Skip everyting before the SPS, then read the SPS and PPS
  if (!reader.SeekToNextNaluOfType(kSps)) {
    return nullptr;
  }
  if (!reader.ReadNalu(&param_set_ptrs[0], &param_set_sizes[0])) {
//    RTC_LOG(LS_ERROR) << "Failed to read SPS";
    return nullptr;
  }
  if (!reader.ReadNalu(&param_set_ptrs[1], &param_set_sizes[1])) {
//    RTC_LOG(LS_ERROR) << "Failed to read PPS";
    return nullptr;
  }

  // Parse the SPS and PPS into a CMVideoFormatDescription.
  CMVideoFormatDescriptionRef description = nullptr;
  OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
      kCFAllocatorDefault, 2, param_set_ptrs, param_set_sizes, 4, &description);
  if (status != noErr) {
//    RTC_LOG(LS_ERROR) << "Failed to create video format description.";
    return nullptr;
  }
  return description;
}

AnnexBBufferReader::AnnexBBufferReader(const uint8_t* annexb_buffer,
                                       size_t length)
    : start_(annexb_buffer), length_(length) {
//  RTC_DCHECK(annexb_buffer);
  offsets_ = H264::FindNaluIndices(annexb_buffer, length);
  offset_ = offsets_.begin();
}

AnnexBBufferReader::~AnnexBBufferReader() = default;

bool AnnexBBufferReader::ReadNalu(const uint8_t** out_nalu,
                                  size_t* out_length) {
//  RTC_DCHECK(out_nalu);
//  RTC_DCHECK(out_length);
  *out_nalu = nullptr;
  *out_length = 0;

  if (offset_ == offsets_.end()) {
    return false;
  }
  *out_nalu = start_ + offset_->payload_start_offset;
  *out_length = offset_->payload_size;
  ++offset_;
  return true;
}

size_t AnnexBBufferReader::BytesRemaining() const {
  if (offset_ == offsets_.end()) {
    return 0;
  }
  return length_ - offset_->start_offset;
}

void AnnexBBufferReader::SeekToStart() {
  offset_ = offsets_.begin();
}

bool AnnexBBufferReader::SeekToNextNaluOfType(NaluType type) {
  for (; offset_ != offsets_.end(); ++offset_) {
    if (offset_->payload_size < 1)
      continue;
    if (ParseNaluType(*(start_ + offset_->payload_start_offset)) == type)
      return true;
  }
  return false;
}
AvccBufferWriter::AvccBufferWriter(uint8_t* const avcc_buffer, size_t length)
    : start_(avcc_buffer), offset_(0), length_(length) {
//  RTC_DCHECK(avcc_buffer);
}

bool AvccBufferWriter::WriteNalu(const uint8_t* data, size_t data_size) {
  // Check if we can write this length of data.
  if (data_size + kAvccHeaderByteSize > BytesRemaining()) {
    return false;
  }
  // Write length header, which needs to be big endian.
  uint32_t big_endian_length = CFSwapInt32HostToBig(data_size);
  memcpy(start_ + offset_, &big_endian_length, sizeof(big_endian_length));
  offset_ += sizeof(big_endian_length);
  // Write data.
  memcpy(start_ + offset_, data, data_size);
  offset_ += data_size;
  return true;
}

size_t AvccBufferWriter::BytesRemaining() const {
  return length_ - offset_;
}

}  // namespace webrtc

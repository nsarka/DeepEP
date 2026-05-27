// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved
#pragma once

#ifndef USE_NIXL

#include "config.cuh"
#include "doca_gpunetio_host.h"
#include <cstdint>

struct doca_verbs_cc_group;

/** DOCA Verbs SDK CC hint groups (SPC-X), gated by HYBRID_EP_CC_HINTS=1. */
class InternodeCcHints {
public:
  bool try_init(doca_dev_t *net_dev, int node_rank, int local_rank);
  void fini();

  bool active() const { return active_; }

  struct doca_verbs_cc_group *dispatch_cc_group() const {
    return reinterpret_cast<struct doca_verbs_cc_group *>(dispatch_cc_group_);
  }
  struct doca_verbs_cc_group *combine_cc_group() const {
    return reinterpret_cast<struct doca_verbs_cc_group *>(combine_cc_group_);
  }

  void push_routing_from_global_map(const bool *global_routing_map, int node_rank, int local_rank,
                                    const BufferConfig &config, int num_of_tokens_per_rank,
                                    uint32_t phase, uint32_t qps_per_dst_for_phase);

private:
  void *dispatch_cc_group_ = nullptr;
  void *combine_cc_group_ = nullptr;
  void *cc_attr_dispatch_ = nullptr;
  void *cc_attr_combine_ = nullptr;
  bool active_ = false;
};

#endif  // !USE_NIXL

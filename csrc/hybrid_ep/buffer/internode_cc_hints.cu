// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved

#ifndef USE_NIXL

#include "buffer/internode_cc_hints.cuh"
#include "doca_verbs_qp_sdk_wrapper.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>

namespace {

enum {
  CC_HINTS_VENDOR_ID_NVIDIA_SPCX = 0x2
};

enum {
  CC_HINTS_VERSION_SPCX_V1 = 0x1,
  CC_HINTS_VERSION_SPCX_V2 = 0x2,
};

enum SpcxCcHintBits : uint32_t {
  SPCX_CC_HINT_TX_PRIORITY = 1u << 31,
  SPCX_CC_HINT_CC_SLOT = 1u << 30,
  SPCX_CC_HINT_INCAST_FACTOR = 1u << 15,
  SPCX_CC_HINT_QPS_PER_DST = 1u << 14,
  SPCX_CC_HINT_TOPOLOGY_LATENCY = 1u << 13,
  SPCX_CC_HINT_FIELD_VALID = 1u << 0
};

#define SPCX_CC_HINT_INCAST_FACTOR_MAX 256
#define SPCX_CC_HINT_QPS_PER_DST_MAX 256
#define SPCX_CC_HINT_INCAST_FACTOR_MIN 1
#define SPCX_CC_HINT_QPS_PER_DST_MIN 1
#define SPCX_CC_HINT_CC_SLOT_MAX 15
#define SPCX_CC_HINT_CC_SLOT_MIN 0

#pragma pack(push, 1)
struct spcx_cc_hint_data {
  uint32_t field_mask;
  uint8_t tx_priority;
  uint8_t cc_slot;
  uint8_t reserve_1[2];
  uint32_t incast_factor;
  uint32_t qps_per_dst;
  uint32_t topology_latency;
  uint32_t clear_cc_ctx;
};

struct cc_group_caps {
  uint32_t vendor_id;
  uint32_t version;
  uint64_t hint_fields;
  uint64_t hint_value_range[4];
};
#pragma pack(pop)

static_assert(sizeof(cc_group_caps) == 48, "cc_group_caps must be 48 bytes");
static_assert(sizeof(spcx_cc_hint_data) == 24, "spcx_cc_hint_data must be 24 bytes");

constexpr size_t kCcHintsCapBytesMin = sizeof(cc_group_caps);
constexpr size_t kCcHintsDataBytes = sizeof(spcx_cc_hint_data);

struct CcCapsParsed {
  bool valid = false;
  uint32_t vendor_id = 0;
  uint32_t version = 0;
  uint64_t hint_fields = 0;
  uint16_t cc_algo_slot_bitmap = 0;
};

static CcCapsParsed g_cc_caps;

static bool cc_env_enabled() {
  const char *env = std::getenv("HYBRID_EP_CC_HINTS");
  return env != nullptr && env[0] == '1';
}

static bool cc_cap_field_supported(uint64_t cap_hint_fields, uint64_t field_bit) {
  if (cap_hint_fields == 0) {
    return true;
  }
  if (cap_hint_fields == static_cast<uint64_t>(SPCX_CC_HINT_FIELD_VALID)) {
    return false;
  }
  return (cap_hint_fields & field_bit) != 0;
}

static uint8_t pick_cc_algo_slot(uint16_t bitmap) {
  if (bitmap == 0) {
    return 0;
  }
  for (int s = SPCX_CC_HINT_CC_SLOT_MIN; s <= SPCX_CC_HINT_CC_SLOT_MAX; s++) {
    if (bitmap & (1u << s)) {
      return static_cast<uint8_t>(s);
    }
  }
  return 0;
}

static uint32_t clamp_u32(uint32_t v, uint32_t lo, uint32_t hi) {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

static bool query_cc_hints_caps(doca_dev_t *net_dev, CcCapsParsed *out) {
  memset(out, 0, sizeof(*out));
  void *caps_obj = nullptr;
  if (doca_verbs_sdk_wrapper_query_cc_group_caps(net_dev, &caps_obj) != DOCA_SDK_WRAPPER_SUCCESS ||
      caps_obj == nullptr) {
    fprintf(stderr, "[Hybrid-EP] CC hints: doca_verbs_sdk_wrapper_query_cc_group_caps failed\n");
    return false;
  }
  const void *blob = nullptr;
  size_t blob_sz = 0;
  if (doca_verbs_sdk_wrapper_cc_group_caps_get_data(caps_obj, &blob, &blob_sz) !=
          DOCA_SDK_WRAPPER_SUCCESS ||
      blob == nullptr || blob_sz < kCcHintsCapBytesMin) {
    doca_verbs_sdk_wrapper_cc_group_caps_free(caps_obj);
    fprintf(stderr, "[Hybrid-EP] CC hints: doca_verbs_sdk_wrapper_cc_group_caps_get_data failed\n");
    return false;
  }
  cc_group_caps cap_copy{};
  memcpy(&cap_copy, blob, sizeof(cap_copy));
  out->vendor_id = cap_copy.vendor_id;
  out->version = cap_copy.version;
  out->hint_fields = cap_copy.hint_fields;
  out->cc_algo_slot_bitmap = static_cast<uint16_t>(cap_copy.hint_value_range[0] & 0xFFFFu);
  out->valid = true;
  doca_verbs_sdk_wrapper_cc_group_caps_free(caps_obj);
  return true;
}

static void build_spcx_cc_hints(const CcCapsParsed &caps, uint32_t qps_per_dst, uint32_t incast_factor,
                                uint32_t topology_latency_ns, uint8_t cc_slot_preferred, uint8_t tx_priority,
                                spcx_cc_hint_data *out) {
  memset(out, 0, sizeof(*out));
  if (!caps.valid || caps.vendor_id != CC_HINTS_VENDOR_ID_NVIDIA_SPCX ||
      (caps.version != CC_HINTS_VERSION_SPCX_V1 && caps.version != CC_HINTS_VERSION_SPCX_V2)) {
    return;
  }

  uint32_t mask = 0;
  qps_per_dst = clamp_u32(qps_per_dst, SPCX_CC_HINT_QPS_PER_DST_MIN, SPCX_CC_HINT_QPS_PER_DST_MAX);
  if (cc_cap_field_supported(caps.hint_fields, static_cast<uint64_t>(SPCX_CC_HINT_QPS_PER_DST)) &&
      qps_per_dst != 0) {
    out->qps_per_dst = qps_per_dst;
    mask |= static_cast<uint32_t>(SPCX_CC_HINT_QPS_PER_DST);
  }

  incast_factor = clamp_u32(incast_factor, SPCX_CC_HINT_INCAST_FACTOR_MIN, SPCX_CC_HINT_INCAST_FACTOR_MAX);
  if (cc_cap_field_supported(caps.hint_fields, static_cast<uint64_t>(SPCX_CC_HINT_INCAST_FACTOR)) &&
      incast_factor != 0) {
    out->incast_factor = incast_factor;
    mask |= static_cast<uint32_t>(SPCX_CC_HINT_INCAST_FACTOR);
  }

  if (cc_cap_field_supported(caps.hint_fields, static_cast<uint64_t>(SPCX_CC_HINT_TOPOLOGY_LATENCY)) &&
      topology_latency_ns != 0) {
    out->topology_latency = topology_latency_ns;
    mask |= static_cast<uint32_t>(SPCX_CC_HINT_TOPOLOGY_LATENCY);
  }

  if (cc_cap_field_supported(caps.hint_fields, static_cast<uint64_t>(SPCX_CC_HINT_CC_SLOT))) {
    uint8_t slot = static_cast<uint8_t>(
        clamp_u32(cc_slot_preferred, SPCX_CC_HINT_CC_SLOT_MIN, SPCX_CC_HINT_CC_SLOT_MAX));
    if (caps.cc_algo_slot_bitmap != 0 && (caps.cc_algo_slot_bitmap & (1u << (slot & 0xF))) == 0) {
      slot = pick_cc_algo_slot(caps.cc_algo_slot_bitmap);
    }
    out->cc_slot = slot;
    mask |= static_cast<uint32_t>(SPCX_CC_HINT_CC_SLOT);
    if (cc_cap_field_supported(caps.hint_fields, static_cast<uint64_t>(SPCX_CC_HINT_TX_PRIORITY)) &&
        tx_priority != 0) {
      out->tx_priority = tx_priority;
      mask |= static_cast<uint32_t>(SPCX_CC_HINT_TX_PRIORITY);
    }
  } else if (cc_cap_field_supported(caps.hint_fields, static_cast<uint64_t>(SPCX_CC_HINT_TX_PRIORITY)) &&
             tx_priority != 0) {
    out->tx_priority = tx_priority;
    mask |= static_cast<uint32_t>(SPCX_CC_HINT_TX_PRIORITY);
  }

  out->field_mask = mask;
}

static doca_error_t cc_group_update_hints(void *cc_group, void **cc_attr_holder,
                                          const spcx_cc_hint_data *hint) {
  doca_sdk_wrapper_error_t w =
      doca_verbs_sdk_wrapper_cc_group_attr_set_hint(*cc_attr_holder, hint, kCcHintsDataBytes);
  if (w != DOCA_SDK_WRAPPER_SUCCESS) {
    return DOCA_ERROR_UNEXPECTED;
  }
  w = doca_verbs_sdk_wrapper_cc_group_modify(cc_group, *cc_attr_holder);
  if (w != DOCA_SDK_WRAPPER_SUCCESS) {
    return DOCA_ERROR_UNEXPECTED;
  }
  return DOCA_SUCCESS;
}

static void routing_count_recv_tokens_per_src_rank(const bool *global_routing_map, int node_rank,
                                                   int local_rank, const BufferConfig &config,
                                                   int num_of_tokens_per_rank, int *out_counts) {
  const int group_size = config.num_of_ranks_per_node * config.num_of_nodes;
  const int my_global_rank = node_rank * config.num_of_ranks_per_node + local_rank;
  const int num_experts_total = config.num_of_experts_per_rank * group_size;

  for (int src = 0; src < group_size; src++) {
    int count = 0;
    for (int t = 0; t < num_of_tokens_per_rank; t++) {
      const bool *row =
          global_routing_map + static_cast<size_t>(src * num_of_tokens_per_rank + t) * num_experts_total;
      bool needed = false;
      for (int e = my_global_rank * config.num_of_experts_per_rank;
           e < (my_global_rank + 1) * config.num_of_experts_per_rank; e++) {
        if (row[e]) {
          needed = true;
          break;
        }
      }
      if (needed) {
        count++;
      }
    }
    out_counts[src] = count;
  }
}

static uint32_t routing_max_peer_nodes_with_traffic(const int *per_rank_counts, int num_nodes,
                                                    int ranks_per_node) {
  const int group_size = ranks_per_node * num_nodes;
  bool node_has_traffic[256];
  if (num_nodes > static_cast<int>(sizeof(node_has_traffic) / sizeof(node_has_traffic[0]))) {
    return 1;
  }
  for (int n = 0; n < num_nodes; n++) {
    node_has_traffic[n] = false;
  }
  for (int r = 0; r < group_size; r++) {
    if (per_rank_counts[r] <= 0) {
      continue;
    }
    int node = r / ranks_per_node;
    node_has_traffic[node] = true;
  }
  int count = 0;
  for (int n = 0; n < num_nodes; n++) {
    if (node_has_traffic[n]) {
      count++;
    }
  }
  if (count <= 1) {
    return 1;
  }
  return static_cast<uint32_t>(count - 1);
}

static bool cc_init_groups(doca_dev_t *net_dev, void **out_disp_grp, void **out_comb_grp, void **out_attr_d,
                           void **out_attr_c, int node_rank) {
  memset(&g_cc_caps, 0, sizeof(g_cc_caps));
  if (!query_cc_hints_caps(net_dev, &g_cc_caps)) {
    return false;
  }
  if (!g_cc_caps.valid || g_cc_caps.vendor_id != CC_HINTS_VENDOR_ID_NVIDIA_SPCX ||
      (g_cc_caps.version != CC_HINTS_VERSION_SPCX_V1 && g_cc_caps.version != CC_HINTS_VERSION_SPCX_V2)) {
    if (node_rank == 0) {
      fprintf(stderr,
              "[Hybrid-EP] CC hints: caps vendor_id=0x%x version=0x%x "
              "(need NVIDIA-SPC-X vendor 0x%x, version 0x%x or 0x%x).\n",
              g_cc_caps.vendor_id, g_cc_caps.version, CC_HINTS_VENDOR_ID_NVIDIA_SPCX,
              CC_HINTS_VERSION_SPCX_V1, CC_HINTS_VERSION_SPCX_V2);
    }
    memset(&g_cc_caps, 0, sizeof(g_cc_caps));
    return false;
  }

  if (g_cc_caps.hint_fields != 0 &&
      (g_cc_caps.hint_fields & static_cast<uint64_t>(SPCX_CC_HINT_CC_SLOT)) == 0) {
    if (node_rank == 0) {
      fprintf(stderr,
              "[Hybrid-EP] CC hints: device reports hint_fields=0x%llx but CC slot is required.\n",
              static_cast<unsigned long long>(g_cc_caps.hint_fields));
    }
    memset(&g_cc_caps, 0, sizeof(g_cc_caps));
    return false;
  }

  if (!cc_cap_field_supported(g_cc_caps.hint_fields,
                              static_cast<uint64_t>(SPCX_CC_HINT_INCAST_FACTOR))) {
    if (node_rank == 0) {
      fprintf(stderr,
              "[Hybrid-EP] CC hints: device hint_fields=0x%llx does not advertise "
              "SPCX_CC_HINT_INCAST_FACTOR (required when HYBRID_EP_CC_HINTS=1).\n",
              static_cast<unsigned long long>(g_cc_caps.hint_fields));
    }
    memset(&g_cc_caps, 0, sizeof(g_cc_caps));
    return false;
  }

  spcx_cc_hint_data init_hint{};
  doca_sdk_wrapper_error_t er = doca_verbs_sdk_wrapper_cc_group_attr_create(out_attr_d);
  if (er != DOCA_SDK_WRAPPER_SUCCESS) {
    return false;
  }
  er = doca_verbs_sdk_wrapper_cc_group_attr_set_hint(*out_attr_d, &init_hint, sizeof(init_hint));
  if (er != DOCA_SDK_WRAPPER_SUCCESS) {
    doca_verbs_sdk_wrapper_cc_group_attr_destroy(*out_attr_d);
    *out_attr_d = nullptr;
    return false;
  }
  er = doca_verbs_sdk_wrapper_cc_group_create(net_dev, *out_attr_d, out_disp_grp);
  if (er != DOCA_SDK_WRAPPER_SUCCESS) {
    doca_verbs_sdk_wrapper_cc_group_attr_destroy(*out_attr_d);
    *out_attr_d = nullptr;
    return false;
  }
  er = doca_verbs_sdk_wrapper_cc_group_attr_create(out_attr_c);
  if (er != DOCA_SDK_WRAPPER_SUCCESS) {
    doca_verbs_sdk_wrapper_cc_group_destroy(*out_disp_grp);
    *out_disp_grp = nullptr;
    doca_verbs_sdk_wrapper_cc_group_attr_destroy(*out_attr_d);
    *out_attr_d = nullptr;
    return false;
  }
  er = doca_verbs_sdk_wrapper_cc_group_attr_set_hint(*out_attr_c, &init_hint, sizeof(init_hint));
  if (er != DOCA_SDK_WRAPPER_SUCCESS) {
    doca_verbs_sdk_wrapper_cc_group_destroy(*out_disp_grp);
    *out_disp_grp = nullptr;
    doca_verbs_sdk_wrapper_cc_group_attr_destroy(*out_attr_d);
    *out_attr_d = nullptr;
    doca_verbs_sdk_wrapper_cc_group_attr_destroy(*out_attr_c);
    *out_attr_c = nullptr;
    return false;
  }
  er = doca_verbs_sdk_wrapper_cc_group_create(net_dev, *out_attr_c, out_comb_grp);
  if (er != DOCA_SDK_WRAPPER_SUCCESS) {
    doca_verbs_sdk_wrapper_cc_group_destroy(*out_disp_grp);
    *out_disp_grp = nullptr;
    doca_verbs_sdk_wrapper_cc_group_attr_destroy(*out_attr_d);
    *out_attr_d = nullptr;
    doca_verbs_sdk_wrapper_cc_group_attr_destroy(*out_attr_c);
    *out_attr_c = nullptr;
    return false;
  }
  return true;
}

}  // namespace

bool InternodeCcHints::try_init(doca_dev_t *net_dev, int node_rank) {
  fini();
  if (!cc_env_enabled() || net_dev == nullptr) {
    return false;
  }
  if (!cc_init_groups(net_dev, &dispatch_cc_group_, &combine_cc_group_, &cc_attr_dispatch_,
                    &cc_attr_combine_, node_rank)) {
    if (node_rank == 0) {
      fprintf(stderr,
              "[Hybrid-EP] HYBRID_EP_CC_HINTS=1 but CC init failed "
              "(set DOCA_SDK_LIB_PATH to Mellanox DOCA SDK with CC group support).\n");
    }
    return false;
  }
  active_ = true;
  if (node_rank == 0) {
    fprintf(stderr, "[Hybrid-EP] CC hints enabled (vendor=0x%x version=0x%x hint_fields=0x%llx)\n",
            g_cc_caps.vendor_id, g_cc_caps.version,
            static_cast<unsigned long long>(g_cc_caps.hint_fields));
  }
  return true;
}

void InternodeCcHints::fini() {
  if (combine_cc_group_) {
    doca_verbs_sdk_wrapper_cc_group_destroy(combine_cc_group_);
    combine_cc_group_ = nullptr;
  }
  if (dispatch_cc_group_) {
    doca_verbs_sdk_wrapper_cc_group_destroy(dispatch_cc_group_);
    dispatch_cc_group_ = nullptr;
  }
  if (cc_attr_combine_) {
    doca_verbs_sdk_wrapper_cc_group_attr_destroy(cc_attr_combine_);
    cc_attr_combine_ = nullptr;
  }
  if (cc_attr_dispatch_) {
    doca_verbs_sdk_wrapper_cc_group_attr_destroy(cc_attr_dispatch_);
    cc_attr_dispatch_ = nullptr;
  }
  memset(&g_cc_caps, 0, sizeof(g_cc_caps));
  active_ = false;
}

void InternodeCcHints::push_routing_from_global_map(const bool *global_routing_map, int node_rank,
                                                    int local_rank, const BufferConfig &config,
                                                    int num_of_tokens_per_rank, uint32_t phase,
                                                    uint32_t qps_per_dst_for_phase) {
  if (!active_ || global_routing_map == nullptr || !g_cc_caps.valid) {
    return;
  }

  void *cc_group = (phase == 0) ? dispatch_cc_group_ : combine_cc_group_;
  void **cc_attr = (phase == 0) ? &cc_attr_dispatch_ : &cc_attr_combine_;
  if (cc_group == nullptr || cc_attr == nullptr || *cc_attr == nullptr) {
    return;
  }

  const int group_size = config.num_of_ranks_per_node * config.num_of_nodes;
  int per_rank_counts[256];
  if (group_size > static_cast<int>(sizeof(per_rank_counts) / sizeof(per_rank_counts[0]))) {
    return;
  }
  routing_count_recv_tokens_per_src_rank(global_routing_map, node_rank, local_rank, config,
                                         num_of_tokens_per_rank, per_rank_counts);

  uint32_t incast = routing_max_peer_nodes_with_traffic(per_rank_counts, config.num_of_nodes,
                                                        config.num_of_ranks_per_node);
  if (config.num_of_nodes > 1) {
    const uint32_t cap = static_cast<uint32_t>(config.num_of_nodes - 1);
    if (incast > cap) {
      incast = cap;
    }
  }

  spcx_cc_hint_data hint{};
  const uint8_t preferred_slot = pick_cc_algo_slot(g_cc_caps.cc_algo_slot_bitmap);
  build_spcx_cc_hints(g_cc_caps, qps_per_dst_for_phase, incast, 0u, preferred_slot, 0u, &hint);

  if (cc_group_update_hints(cc_group, cc_attr, &hint) != DOCA_SUCCESS) {
    fprintf(stderr,
            "[Hybrid-EP] CC hint update failed (phase=%u node_rank=%d local_rank=%d) "
            "field_mask=0x%x incast=%u qps_per_dst=%u\n",
            phase, node_rank, local_rank, hint.field_mask, hint.incast_factor, hint.qps_per_dst);
  }
}

#endif  // !USE_NIXL

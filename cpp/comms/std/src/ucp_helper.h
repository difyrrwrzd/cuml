/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <dlfcn.h>
#include <stdio.h>
#include <ucp/api/ucp.h>
#include <ucp/api/ucp_def.h>
#include <utils.h>
#include <cuml/common/logger.hpp>
#include <cuml/common/utils.hpp>

#pragma once


/**
 * Standard UCX request object that will be passed
 * around asynchronously. This object is really
 * opaque and the comms layer only cares that it
 * has been completed. Because cuml comms do not
 * initialize the ucx application context, it doesn't
 * own this object and thus it's important not to
 * modify this struct.
 */
struct ucx_context {
  int completed;
};

/**
 * Wraps the `ucx_context` request and adds a few
 * other fields for trace logging and cleanup.
 */
class ucp_request {
  public:
    struct ucx_context* req;
    bool needs_release = true;
    int other_rank = -1;
    bool is_send_request = false;
};


// by default, match the whole tag
static const ucp_tag_t default_tag_mask = -1;

// Only match the passed in tag, not the rank. This
// enables simulated multi-cast.
static const ucp_tag_t any_rank_tag_mask = 0xFFFF0000;

// Per the MPI API, receiving from a rank of -1 denotes receiving
// from any rank that used the expected tag.
static const int UCP_ANY_RANK = -1;

/**
 * @brief Asynchronous send callback sets request to completed
 */
static void send_callback(void *request, ucs_status_t status) {
  struct ucx_context *context = (struct ucx_context *)request;
  context->completed = 1;
}

/**
 * @brief Asynchronous recv callback sets request to completed
 */
static void recv_callback(void *request, ucs_status_t status,
                        ucp_tag_recv_info_t *info) {
  struct ucx_context *context = (struct ucx_context *)request;
  context->completed = 1;
}


/**
 * Helper class for managing `dlopen` state and
 * interacting with ucp.
 */
class comms_ucp_handler {
public:
  comms_ucp_handler() {
    load_ucp_handle();
    load_send_func();
    load_recv_func();
    load_free_req_func();
    load_print_info_func();
    load_worker_progress_func();
  }

  ~comms_ucp_handler() {
    dlclose(ucp_handle);
  }

private:
  void *ucp_handle;

  ucs_status_ptr_t (*send_func)(ucp_ep_h, const void *, size_t, ucp_datatype_t,
                                ucp_tag_t, ucp_send_callback_t);
  ucs_status_ptr_t (*recv_func)(ucp_worker_h, void *, size_t count,
                                ucp_datatype_t datatype, ucp_tag_t, ucp_tag_t,
                                ucp_tag_recv_callback_t);
  void (*print_info_func)(ucp_ep_h, FILE *);
  void (*req_free_func)(void *);
  int (*worker_progress_func)(ucp_worker_h);
  void load_ucp_handle() {
    ucp_handle =
      dlopen("libucp.so", RTLD_LAZY | RTLD_NOLOAD | RTLD_NODELETE);
    if (!ucp_handle) {
      ucp_handle = dlopen("libucp.so", RTLD_LAZY | RTLD_NODELETE);
      ASSERT(ucp_handle, "Cannot open UCX library: %s\n", dlerror());
    }
    dlerror();
  }

  void assert_dlerror() {
    char *error = dlerror();
    ASSERT(error == NULL, "Error loading function symbol: %s\n", error);
  }

  void load_send_func() {
    send_func = (ucs_status_ptr_t(*)(
      ucp_ep_h, const void *, size_t, ucp_datatype_t, ucp_tag_t,
      ucp_send_callback_t))dlsym(ucp_handle, "ucp_tag_send_nb");
    assert_dlerror();
  }

  void load_free_req_func() {
    req_free_func =
      (void (*)(void *request))dlsym(ucp_handle, "ucp_request_free");
    assert_dlerror();
  }

  void load_print_info_func() {
    print_info_func = (void (*)(ucp_ep_h, FILE *))dlsym(
      ucp_handle, "ucp_ep_print_info");
    assert_dlerror();
  }

  void load_worker_progress_func() {
    worker_progress_func =
      (int (*)(ucp_worker_h))dlsym(ucp_handle, "ucp_worker_progress");
    assert_dlerror();
  }

  void load_recv_func() {
    recv_func = (ucs_status_ptr_t(*)(
      ucp_worker_h, void *, size_t, ucp_datatype_t, ucp_tag_t, ucp_tag_t,
      ucp_tag_recv_callback_t))dlsym(ucp_handle, "ucp_tag_recv_nb");
    assert_dlerror();
  }

  ucp_tag_t build_message_tag(int rank, int tag) const {
    // keeping the rank in the lower bits enables debugging.
    return ((uint32_t)tag << 31) | (uint32_t)rank;
  }


public:
  int ucp_progress(ucp_worker_h worker) const {
    return (*(worker_progress_func))(worker);
  }


  /**
   * @brief Frees any memory underlying the given ucp request object
   */
  void free_ucp_request(ucp_request *request) const {
    if (request->needs_release) {
      request->req->completed = 0;
      (*(req_free_func))(request->req);
    }
    free(request);
  }

  /**
   * @brief Asynchronously send data to the given endpoint using the given tag
   */
  void ucp_isend(ucp_request *req, ucp_ep_h ep_ptr,
      const void *buf, int size, int tag, ucp_tag_t tag_mask, int rank,
                                bool verbose) const {
    ucp_tag_t ucp_tag = build_message_tag(rank, tag);

    CUML_LOG_DEBUG("Sending tag: %ld", ucp_tag);

    ucs_status_ptr_t send_result = (*(send_func))(
      ep_ptr, buf, size, ucp_dt_make_contig(1), ucp_tag, send_callback);
    struct ucx_context *ucp_req = (struct ucx_context *)send_result;
    if (UCS_PTR_IS_ERR(send_result)) {
      ASSERT(!UCS_PTR_IS_ERR(send_result),
             "unable to send UCX data message (%d)\n",
             UCS_PTR_STATUS(send_result));
      /**
     * If the request didn't fail, but it's not OK, it is in flight.
     * Expect the handler to be invoked
     */
    } else if (UCS_PTR_STATUS(send_result) != UCS_OK) {
      /**
      * If the request is OK, it's already been completed and we don't need to wait on it.
      * The request will be a nullptr, however, so we need to create a new request
      * and set it to completed to make the "waitall()" function work properly.
      */
      req->needs_release = true;
    } else {
      req->needs_release = false;
    }

    req->other_rank = rank;
    req->is_send_request = true;
    req->req = ucp_req;
  }

  /**
   * @brief Asynchronously receive data from given endpoint with the given tag.
   */
  void ucp_irecv(ucp_request *req,
      ucp_worker_h worker, ucp_ep_h ep_ptr, void *buf,
      int size, int tag, ucp_tag_t tag_mask,
      int sender_rank, bool verbose) const {
    ucp_tag_t ucp_tag = build_message_tag(sender_rank, tag);

    CUML_LOG_DEBUG("%d: Receiving tag: %ld", ucp_tag);

    ucs_status_ptr_t recv_result = (*(recv_func))(
      worker, buf, size, ucp_dt_make_contig(1), ucp_tag, tag_mask, recv_callback);

    struct ucx_context *ucp_req = (struct ucx_context *)recv_result;

    req->req = ucp_req;
    req->needs_release = true;
    req->is_send_request = false;
    req->other_rank = sender_rank;

    ASSERT(!UCS_PTR_IS_ERR(recv_result),
           "unable to receive UCX data message (%d)\n",
           UCS_PTR_STATUS(recv_result));
  }
};

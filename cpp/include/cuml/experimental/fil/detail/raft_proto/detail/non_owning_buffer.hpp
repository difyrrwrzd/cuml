/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
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
#pragma once
#include <cuml/experimental/fil/detail/raft_proto/device_type.hpp>
#include <cuml/experimental/fil/detail/raft_proto/detail/non_owning_buffer/base.hpp>

namespace raft_proto {
template<device_type D, typename T>
using non_owning_buffer = detail::non_owning_buffer<D, T>;
}

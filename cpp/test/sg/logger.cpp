/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <string>
#include <gtest/gtest.h>
#include <cuml/common/logger.hpp>

namespace ML {

TEST(Logger, Test) {
  CUML_LOG_CRITICAL("This is a critical message");
  CUML_LOG_ERROR("This is an error message");
  CUML_LOG_WARN("This is a warning message");
  CUML_LOG_INFO("This is an info message");

  Logger::get().setLevel(CUML_LEVEL_WARN);
  ASSERT_EQ(CUML_LEVEL_WARN, Logger::get().getLevel());
  Logger::get().setLevel(CUML_LEVEL_INFO);
  ASSERT_EQ(CUML_LEVEL_INFO, Logger::get().getLevel());

  ASSERT_FALSE(Logger::get().shouldLogFor(CUML_LEVEL_TRACE));
  ASSERT_FALSE(Logger::get().shouldLogFor(CUML_LEVEL_DEBUG));
  ASSERT_TRUE(Logger::get().shouldLogFor(CUML_LEVEL_INFO));
  ASSERT_TRUE(Logger::get().shouldLogFor(CUML_LEVEL_WARN));
}


std::string logged = "";
void exampleCallback(int lvl, const char * msg) {
  logged = std::string(msg);
}

TEST(Logger, callback) {
  Logger::get().setCallback(exampleCallback);
  Logger::get().setLevel(CUML_LEVEL_TRACE);

  std::string testMsg;

  testMsg = "This is a critical message";
  CUML_LOG_CRITICAL(testMsg.c_str());
  ASSERT_TRUE(logged.find(testMsg) != std::string::npos);

  testMsg = "This is an error message";
  CUML_LOG_ERROR(testMsg.c_str());
  ASSERT_TRUE(logged.find(testMsg) != std::string::npos);

  testMsg = "This is a warning message";
  CUML_LOG_WARN(testMsg.c_str());
  ASSERT_TRUE(logged.find(testMsg) != std::string::npos);

  testMsg = "This is an info message";
  CUML_LOG_INFO(testMsg.c_str());
  ASSERT_TRUE(logged.find(testMsg) != std::string::npos);

  testMsg = "This is a debug message";
  CUML_LOG_DEBUG(testMsg.c_str());
  ASSERT_TRUE(logged.find(testMsg) != std::string::npos);

}

}  // namespace ML

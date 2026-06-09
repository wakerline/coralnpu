# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import numpy as np


INPUT_DIMS = np.array([1, 1, 1, 16], dtype=np.int32)
HIDDEN_DIMS = np.array([1, 1, 1, 8], dtype=np.int32)
OUTPUT_DIMS = np.array([1, 1, 1, 4], dtype=np.int32)
FC1_FILTER_DIMS = np.array([8, 1, 1, 16], dtype=np.int32)
FC1_BIAS_DIMS = np.array([8], dtype=np.int32)
FC2_FILTER_DIMS = np.array([4, 1, 1, 8], dtype=np.int32)
FC2_BIAS_DIMS = np.array([4], dtype=np.int32)

INPUT_DATA = np.array(
    [16, -8, 31, -24, 7, 12, -19, 5, 28, -3, -14, 21, 9, -30, 18, -11],
    dtype=np.int8,
)

FC1_FILTER_DATA = np.array(
    [
        3, -2, 5, 1, -4, 2, 0, -1, 4, 3, -5, 2, 1, -3, 2, -2,
        -4, 1, 2, -3, 5, 0, -2, 4, -1, 2, 3, -5, 2, 1, -3, 3,
        2, 4, -1, 3, -2, 5, 1, 0, -3, 2, -4, 1, 3, -5, 2, 4,
        1, -5, 3, 2, 4, -1, 5, -3, 2, 0, -2, 3, -4, 1, 5, -2,
        -2, 3, -4, 5, 1, -3, 4, 2, 0, -1, 3, -5, 4, 2, -2, 1,
        5, 2, 1, -4, 3, -2, 4, -5, 1, 3, -1, 2, -3, 5, 0, -2,
        -1, 4, 2, -5, 3, 1, -4, 5, -2, 3, 0, -3, 2, -1, 4, 1,
        4, -3, 1, 5, -2, 3, -5, 2, 1, -4, 5, 0, -1, 3, -2, 4,
    ],
    dtype=np.int8,
)

FC1_BIAS_DATA = np.array([12, -18, 7, -5, 21, -9, 3, 15], dtype=np.int32)

FC2_FILTER_DATA = np.array(
    [
        4, -3, 5, 2, -4, 3, 1, -2,
        -5, 4, -2, 3, 5, -1, 2, 1,
        3, 1, -4, 5, -2, 4, -3, 2,
        -2, 5, 3, -4, 1, -5, 4, 3,
    ],
    dtype=np.int8,
)

FC2_BIAS_DATA = np.array([5, -7, 11, -3], dtype=np.int32)

EXPECTED_CLASS = 0

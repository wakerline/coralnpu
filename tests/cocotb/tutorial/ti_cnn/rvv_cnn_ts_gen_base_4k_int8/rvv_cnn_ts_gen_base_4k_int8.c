// Generated from TI TimeSeries Generic quantized ONNX.
//
// SPDX-License-Identifier: Apache-2.0

#include <riscv_vector.h>
#include <stddef.h>
#include <stdint.h>

#include "rvv_cnn_ts_gen_base_4k_int8.h"

static const int8_t input_q[RVV_CNN_TS_GEN_BASE_4K_INT8_INPUT_LEN] = {
    118, 4,   -9,  -18, -22, -41, -31, -30, -25, -29, -27, -35, -36, -40, -33,
    -30, -30, -31, -20, -25, -41, -25, -33, -37, -30, -36, -35, -30, -25, -28,
    -29, -23, -25, -32, -23, -27, -37, -29, -24, -16, 16,  -3,  -27, -33, -34,
    -53, -27, -6,  -8,  -20, -28, -19, -2,  -2,  -12, -14, -31, -22, -17, -9,
    -24, -25, -29, -21, -29, -29, -18, 0,   7,   -3,  -21, -22, -19, -20, -34,
    -34, -23, -28, -21, -6,  26,  77,  57,  1,   -22, -28, -32, -31, -25, -20,
    -29, -31, -40, -30, -36, -32, -31, -32, -1,  3,   -20, -23, -21, -29, -24,
    -29, -29, -40, -34, -42, -36, -27, -32, -34, -28, -29, -36, -36, -36, -36,
    -33, -35, -2,  -18, -36, -37, -28, -9,  -24, -36, -31, -31, -29, -22, -33,
    -47, -40, -38, -26, -28, -31, -38, -36, -21, -25, -46, -39, -27, -41, -30,
    -39, -29, -37, -40, -29, -28, -36, -36, -28, -21, -24, -44, -35, -12, -28,
    -27, -30, -24, -29, -31, -34, -24, -35, -41, -31, -41, -40, -48, -36, -35,
    -39, -35, -26, -22, -23, -47, -28, -33, -29, -17, -29, -29, -24, -32, -30,
    -36, -23, -39, -41, -36, -22, -38, -40, -51, -28, -29, -45, -29, -31, -37,
    -27, -37, -25, -12, -21, -33, -34, -35, -27, -36, -26, -37, -45, -27, -40,
    -32, -26, -37, -28, -30, -40, -36, -36, -23, -40, -45, -33, -39, -34, -28,
    -28, -39, -32, -30, -28, -6,  -20, -33, -30, -24, -28, -29, -37, -39, -22,
    -14};

static const int8_t conv0_weight[56] = {
    -27, 70,  34,  11,  -40, 52,   32,   17,  -45, 8,   -81, -70, -91, -7,
    68,  91,  71,  -21, 35,  -36,  63,   -31, 50,  -48, 55,  69,  27,  9,
    37,  -46, 43,  -64, -17, -105, -120, 72,  25,  2,   16,  65,  -31, -16,
    -28, -67, -51, -45, -31, 12,   -61,  -28, -50, -70, -13, -91, -85, 58};
static const int32_t conv0_offset[8] = {49, -32, 139, 24, 76, 51, -21, 133};
static const uint32_t conv0_shift[8] = {6, 7, 7, 6, 7, 6, 7, 7};

static const int8_t conv1_weight[640] = {
    -21, 54,   111, 56,  83,   34,  114,  95,   3,   8,   121, 55,  -59, 23,
    -40, -110, 2,   -3,  2,    99,  -106, -111, 42,  -92, -46, -55, 120, 102,
    93,  75,   92,  22,  -111, 71,  -44,  24,   8,   -78, -25, -44, -62, -38,
    44,  -60,  -2,  -82, -69,  74,  -47,  71,   44,  -81, -34, -53, 87,  6,
    4,   42,   -83, -22, -53,  -21, -9,   3,    38,  -39, -14, -53, -32, -31,
    -77, 4,    -71, 40,  1,    61,  -7,   70,   76,  38,  31,  -54, 55,  -43,
    -14, -6,   13,  18,  -42,  -36, -55,  53,   -44, 3,   52,  11,  47,  -14,
    -46, -37,  40,  13,  76,   -8,  58,   12,   -50, 12,  6,   11,  -71, -71,
    39,  80,   29,  27,  -31,  19,  -37,  67,   -25, -57, 23,  -24, 53,  -86,
    56,  23,   25,  -2,  69,   19,  55,   -35,  50,  11,  54,  67,  -54, -35,
    -15, -64,  -35, 45,  -78,  2,   42,   -32,  -29, 66,  2,   45,  23,  -3,
    -11, -33,  -84, 57,  -69,  -59, -43,  33,   -73, -30, -12, -22, -8,  -70,
    -41, -17,  -86, 36,  5,    22,  43,   61,   73,  33,  35,  -7,  60,  -12,
    56,  -10,  89,  -43, 1,    87,  46,   77,   -59, 28,  63,  -20, -35, -66,
    39,  -29,  -91, -64, -78,  -65, 55,   12,   -4,  44,  -2,  -83, 10,  -44,
    -8,  -63,  -19, 72,  78,   8,   6,    -48,  83,  -60, 36,  -81, -86, 31,
    -8,  82,   -64, -67, 84,   11,  -1,   79,   -15, 40,  -10, 5,   -44, 36,
    -41, 49,   -84, -33, 69,   72,  -52,  -60,  -68, 39,  -48, 27,  -93, 47,
    93,  -32,  -19, 47,  -57,  -27, -44,  -14,  53,  41,  -83, -26, -19, 41,
    57,  24,   3,   60,  -54,  -3,  -63,  -16,  46,  -37, -94, -57, 82,  -84,
    67,  38,   -99, -49, -65,  -47, -79,  72,   -78, 29,  9,   2,   -30, 55,
    -15, -61,  69,  -32, -84,  -68, 63,   5,    71,  -88, 54,  -54, 52,  -28,
    0,   -6,   21,  -5,  -28,  -93, -34,  36,   -68, -78, -90, -3,  -67, 63,
    61,  -67,  -60, 44,  -28,  -10, 19,   45,   5,   18,  13,  28,  -46, 15,
    79,  39,   56,  9,   -19,  78,  63,   73,   31,  -9,  52,  -46, 49,  -66,
    -65, -18,  1,   11,  32,   -6,  -53,  -39,  -6,  91,  -40, -38, -76, 0,
    -64, 71,   62,  42,  71,   71,  52,   19,   -47, 34,  67,  -87, 72,  64,
    -12, -61,  -35, -33, 26,   15,  86,   -15,  -83, 10,  59,  50,  83,  3,
    33,  -45,  -45, -14, -10,  23,  -33,  38,   41,  0,   32,  51,  19,  40,
    1,   7,    29,  -44, 31,   35,  -9,   -15,  -12, -43, 70,  56,  32,  -29,
    46,  -66,  41,  29,  -7,   -14, -50,  69,   62,  5,   -31, -23, 11,  -33,
    36,  45,   -32, -52, -45,  -47, 13,   -39,  -80, -18, 0,   33,  -34, 45,
    33,  -27,  56,  26,  66,   -61, 8,    -27,  -18, 75,  -22, -69, 40,  46,
    -18, 95,   17,  -12, -25,  1,   -68,  13,   27,  -58, -50, 76,  20,  14,
    64,  -59,  26,  21,  -22,  67,  44,   -57,  22,  76,  81,  0,   6,   75,
    -14, -58,  -73, -24, 14,   -39, -57,  -66,  -66, -67, 54,  -3,  24,  -69,
    78,  69,   21,  48,  -76,  71,  11,   -5,   -59, -52, -1,  1,   40,  -21,
    -31, 3,    16,  -44, -13,  -19, -48,  -56,  -10, 78,  -85, 36,  -55, 16,
    52,  -74,  56,  -25, -6,   5,   5,    85,   37,  -60, 33,  -5,  -13, 10,
    -55, -3,   24,  51,  -25,  8,   -32,  -59,  5,   69,  -65, 1,   -56, -34,
    64,  22,   78,  -78, -46,  76,  25,   -11,  40,  69,  -26, 80,  -58, 34,
    24,  -23,  49,  -48, 28,   -72, -70,  47,   72,  16,  -59, 74,  8,   -44,
    -47, 3,    61,  66,  -49,  -73, 39,   46,   63,  55,  63,  27,  -45, 52,
    -54, -76,  11,  56,  61,   85,  67,   -10,  77,  -77, 29,  70,  -86, 55,
    22,  66,   -49, 11,  70,   23,  -16,  -3,   90,  -31, -57, 53,  -32, 23,
    73,  18,   16,  34,  22,   -62, -91,  -80,  70,  59};
static const int32_t conv1_offset[16] = {
    -18290, 11430, -3314, 2295,  -1582, 3027, 12118,  22296,
    -13321, -9346, -8022, -4031, 3188,  9365, -17062, -14451};
static const uint32_t conv1_shift[16] = {9, 8, 7, 8, 8, 7, 8, 7,
                                         7, 8, 8, 8, 8, 7, 8, 8};

static const int8_t conv2_weight[2560] = {
    36,   -47, 16,   -61,  -37,  -55, 32,  -33,  -42, -16, -30,  -54, 42,
    36,   -51, 25,   33,   -31,  -40, 34,  36,   -41, 36,  -32,  21,  -51,
    -46,  -4,  -32,  -36,  23,   19,  52,  -31,  5,   3,   46,   -21, -33,
    -43,  1,   -29,  22,   -15,  24,  -41, 32,   -38, 49,  -15,  27,  -50,
    -23,  9,   8,    1,    -24,  1,   -16, 1,    -1,  15,  -45,  34,  -38,
    14,   -4,  12,   22,   -28,  10,  5,   -5,   -21, -44, 3,    23,  31,
    -24,  -49, -45,  -24,  23,   -4,  -65, 40,   -53, 27,  50,   -43, 48,
    -41,  -4,  -6,   0,    31,   4,   65,  -3,   -5,  -45, 20,   -60, -16,
    -26,  4,   -53,  45,   35,   52,  54,  -22,  26,  -45, -53,  37,  -43,
    -33,  -56, -4,   -67,  37,   9,   -23, -52,  34,  28,  -21,  -9,  -18,
    28,   19,  45,   9,    -53,  24,  42,  42,   69,  36,  59,   -46, 21,
    18,   0,   56,   -42,  30,   1,   -63, 31,   7,   74,  -7,   -24, 17,
    -10,  -30, 77,   22,   -63,  -63, 31,  24,   23,  -81, 45,   22,  -34,
    36,   -65, -75,  -37,  11,   -62, 34,  -9,   -54, 56,  82,   -64, 4,
    61,   3,   0,    40,   -31,  -79, 25,  -58,  -83, 38,  27,   -50, 80,
    -20,  65,  -47,  36,   7,    54,  46,  20,   -69, -35, 12,   -58, -70,
    -58,  47,  10,   -43,  61,   -12, -53, 19,   -18, -63, 36,   32,  85,
    -20,  8,   31,   71,   16,   61,  56,  -32,  79,  -54, -19,  1,   20,
    -72,  -17, -33,  52,   -43,  4,   7,   71,   17,  -5,  45,   8,   37,
    -59,  -72, 5,    -63,  43,   -37, -31, 36,   -50, -15, 27,   60,  -16,
    10,   7,   33,   -6,   3,    -20, -22, 28,   28,  2,   36,   -35, 46,
    51,   63,  -57,  -58,  39,   59,  21,  0,    69,  -50, 48,   19,  15,
    20,   -32, -12,  56,   73,   44,  21,  -15,  -31, 58,  -64,  20,  -66,
    13,   41,  10,   7,    -8,   37,  9,   -63,  13,  12,  -30,  38,  -15,
    -59,  -56, -54,  31,   60,   -43, 41,  -18,  -46, -67, 34,   -65, 5,
    55,   56,  -12,  39,   -30,  -13, -37, 43,   43,  21,  51,   21,  -4,
    -36,  -54, 37,   -3,   -43,  18,  -50, 43,   53,  -49, 62,   67,  48,
    35,   48,  -15,  47,   14,   -49, 58,  -29,  59,  -59, 42,   -24, -21,
    -5,   20,  36,   -21,  -34,  -6,  -32, 58,   33,  -2,  62,   -62, 40,
    -7,   -56, 34,   57,   36,   -44, -61, -41,  54,  -60, -17,  1,   48,
    54,   -20, -34,  -26,  48,   44,  -34, -59,  25,  37,  20,   -10, -3,
    3,    -92, -80,  -48,  72,   -22, -73, -82,  -65, 15,  -35,  -27, -50,
    -93,  33,  23,   56,   -1,   83,  71,  28,   -14, -22, 11,   95,  32,
    82,   15,  82,   -50,  -104, -92, 21,  73,   31,  -94, 51,   95,  -62,
    83,   -6,  25,   89,   44,   108, 90,  -33,  -80, 43,  -31,  25,  -44,
    99,   70,  74,   -39,  -83,  70,  50,  11,   -81, 72,  46,   82,  49,
    -71,  -85, 27,   -15,  -13,  19,  78,  54,   97,  -63, -46,  28,  -90,
    94,   90,  -78,  -71,  -61,  -14, 54,  17,   -85, 28,  3,    -51, 31,
    -66,  66,  -54,  25,   -70,  -72, -9,  77,   2,   -43, -69,  97,  56,
    -52,  21,  -67,  -6,   -86,  39,  -18, -76,  56,  29,  -36,  109, 97,
    -36,  -56, 6,    -4,   -17,  67,  61,  -92,  51,  13,  3,    61,  -80,
    -57,  94,  -32,  29,   53,   12,  -46, -82,  -36, -30, -100, 0,   16,
    98,   46,  33,   -9,   -69,  -44, 34,  15,   -59, 6,   22,   41,  23,
    -85,  -19, -7,   -29,  -8,   -40, 67,  7,    -65, 55,  33,   -24, 48,
    62,   37,  1,    -5,   41,   1,   -54, -19,  58,  9,   -48,  -55, -1,
    8,    12,  57,   39,   10,   -12, 24,  -66,  68,  -36, 14,   -51, -59,
    -32,  15,  -51,  11,   38,   -32, 60,  60,   3,   -31, 25,   41,  -40,
    28,   -2,  -45,  8,    41,   36,  -6,  57,   42,  46,  -32,  3,   -47,
    -21,  -43, -8,   -38,  19,   59,  42,  -60,  10,  -13, -10,  -10, -50,
    -24,  20,  -36,  12,   -1,   10,  7,   -49,  28,  31,  71,   45,  7,
    -80,  87,  -58,  32,   -81,  -12, -27, -9,   -35, -87, -13,  37,  -79,
    47,   -89, -68,  97,   -24,  54,  61,  -38,  -27, 63,  -69,  -28, -7,
    74,   8,   43,   -4,   -15,  9,   -81, 40,   47,  -27, -19,  -40, -71,
    -42,  24,  64,   83,   42,   57,  -10, -83,  -87, -35, 81,   -63, 78,
    70,   28,  45,   -85,  91,   -84, 99,  -2,   -30, 67,  88,   -86, 5,
    33,   -48, 80,   -39,  2,    -70, -58, 56,   -10, -13, -7,   -89, -26,
    -60,  12,  -83,  42,   -79,  -1,  -5,  -27,  41,  88,  -8,   21,  50,
    -81,  -63, 3,    54,   -51,  -8,  92,  28,   10,  64,  -54,  40,  -35,
    49,   -16, -76,  -23,  45,   40,  -54, 12,   -42, -83, -33,  -54, 28,
    -81,  72,  7,    82,   35,   -25, 26,  -30,  9,   -82, -52,  -95, 27,
    78,   -44, -48,  23,   -38,  47,  -50, 74,   80,  11,  -57,  -97, -46,
    -50,  -22, 4,    -72,  78,   31,  69,  0,    -35, 6,   69,   -6,  -15,
    20,   -15, 37,   47,   -25,  45,  38,  -53,  -32, -17, 15,   75,  67,
    71,   12,  58,   -19,  13,   41,  -3,  -65,  -30, 5,   50,   -14, 55,
    43,   -59, 19,   55,   28,   -62, -8,  -50,  26,  62,  -15,  60,  5,
    60,   -17, 34,   5,    31,   38,  16,  60,   -41, -40, -21,  45,  -52,
    -57,  -73, 44,   -49,  61,   -17, -63, 22,   2,   8,   -40,  9,   -60,
    -40,  1,   -54,  46,   30,   13,  58,  -66,  21,  29,  -31,  51,  39,
    -30,  18,  -75,  -37,  -55,  1,   -62, 48,   36,  -35, -32,  -61, 20,
    18,   -5,  -5,   -47,  69,   52,  48,  -52,  20,  31,  -29,  17,  -43,
    47,   -44, 44,   6,    10,   5,   15,  97,   36,  86,  -22,  -55, -56,
    -30,  -40, 3,    27,   28,   28,  -84, 50,   48,  62,  -8,   35,  -23,
    33,   -38, -94,  -78,  17,   -21, -19, -32,  58,  65,  25,   6,   -71,
    -17,  -5,  -59,  -79,  24,   42,  -20, 9,    29,  -63, -78,  -39, 32,
    -37,  27,  -21,  -24,  -22,  -43, 23,  13,   -9,  8,   -37,  -36, -55,
    23,   29,  -38,  15,   43,   25,  15,  -24,  -7,  -23, 2,    39,  -23,
    45,   47,  41,   -12,  43,   -38, -7,  -22,  -19, 18,  -1,   -39, -43,
    -9,   20,  -44,  -27,  3,    9,   -21, -4,   -60, 15,  -33,  12,  -17,
    45,   -11, -30,  -37,  7,    34,  -14, 14,   10,  22,  -37,  -18, -17,
    14,   -38, 46,   -33,  -25,  -5,  -16, 32,   -52, -35, 29,   -33, 20,
    54,   -52, 23,   56,   -55,  -51, 36,  1,    52,  8,   -39,  36,  -44,
    49,   14,  -16,  36,   -45,  57,  -21, 62,   -53, -14, -15,  1,   -14,
    -13,  -14, -20,  -30,  -47,  25,  39,  32,   -6,  33,  52,   55,  17,
    57,   -20, 33,   12,   30,   -23, 5,   -58,  -34, 36,  -15,  -21, -55,
    -27,  -35, 22,   -50,  2,    33,  -53, -21,  -53, 38,  51,   -14, -43,
    23,   12,  -10,  -3,   37,   -12, 24,  49,   11,  -49, -15,  25,  -47,
    4,    11,  36,   85,   28,   -68, 31,  -54,  -41, 26,  -35,  3,   31,
    -69,  -23, -12,  -3,   -26,  1,   47,  -46,  -57, -43, 33,   -8,  6,
    -31,  -7,  -18,  8,    -48,  -87, -83, 70,   49,  33,  -45,  -67, -4,
    48,   -31, -44,  -50,  -70,  -46, -3,  36,   -53, -35, -41,  65,  -35,
    -52,  -79, -47,  -31,  -8,   1,   26,  56,   41,  19,  -15,  55,  56,
    55,   -46, 11,   -50,  53,   -32, 9,   74,   79,  79,  -39,  49,  54,
    -8,   92,  -53,  -30,  -7,   -63, 59,  -8,   -29, 41,  15,   58,  -63,
    6,    7,   -35,  -4,   0,    67,  45,  54,   52,  -59, -23,  -40, 33,
    -62,  12,  -26,  -7,   -5,   -17, 70,  -53,  -41, -50, 25,   14,  -51,
    -46,  -77, 44,   22,   39,   -47, 48,  -10,  1,   47,  -2,   31,  -49,
    22,   11,  14,   45,   34,   -14, -32, 63,   0,   39,  26,   -71, -59,
    -47,  74,  -46,  44,   -54,  -5,  38,  -27,  39,  48,  61,   -32, 47,
    47,   68,  4,    65,   -57,  16,  31,  61,   -10, 63,  106,  26,  62,
    1,    41,  36,   -87,  23,   -35, 36,  -36,  -36, -5,  69,   -46, -35,
    47,   34,  50,   15,   21,   80,  -90, 23,   -70, -4,  82,   79,  40,
    104,  18,  65,   94,   -18,  11,  3,   -18,  27,  84,  50,   -18, -67,
    -80,  -4,  23,   59,   -27,  -76, 78,  -60,  -71, 32,  63,   31,  -73,
    53,   -90, 82,   -36,  -55,  9,   20,  38,   -83, 1,   -47,  80,  3,
    32,   2,   48,   -46,  39,   -75, 49,  -83,  -83, -5,  61,   7,   50,
    93,   28,  -72,  -91,  -38,  46,  -41, -5,   53,  32,  71,   -23, -19,
    -68,  12,  20,   13,   -7,   -28, -26, -68,  -85, 77,  -27,  74,  57,
    -4,   -29, 39,   59,   -7,   -55, -1,  8,    60,  33,  38,   -47, -42,
    -19,  15,  -79,  80,   72,   -71, 21,  55,   99,  53,  91,   -25, -91,
    59,   -4,  -31,  88,   -61,  -23, 9,   -13,  -23, -91, -19,  -60, -57,
    -70,  13,  -30,  -8,   -30,  -6,  -92, 9,    -74, 45,  -69,  31,  -59,
    -79,  -48, 94,   -59,  84,   -16, -28, -23,  41,  -32, -25,  -39, 1,
    -16,  -54, 67,   -28,  -91,  -52, -23, 28,   65,  43,  -71,  -51, 10,
    -32,  -87, 15,   -56,  69,   68,  -66, 38,   15,  -30, -3,   78,  61,
    14,   17,  39,   -57,  2,    -34, 27,  -22,  52,  -69, 13,   46,  -84,
    12,   27,  -50,  52,   75,   82,  -1,  7,    -31, -1,  -61,  95,  45,
    100,  17,  -47,  77,   -46,  -75, -65, -56,  53,  -33, 48,   63,  63,
    8,    -65, -56,  1,    51,   23,  -72, 61,   8,   -5,  -61,  -43, -10,
    34,   54,  32,   71,   62,   4,   47,  51,   25,  6,   16,   -15, 12,
    41,   -7,  48,   62,   28,   45,  -56, -36,  40,  -50, -2,   -20, 13,
    18,   5,   -34,  -51,  0,    -29, -18, -43,  32,  14,  70,   -46, 44,
    -46,  -4,  47,   40,   -40,  58,  -34, -4,   -29, -66, 51,   -67, -28,
    42,   -32, -1,   31,   38,   58,  -66, 45,   25,  -29, -8,   -26, 53,
    4,    9,   12,   46,   -33,  29,  5,   1,    67,  -36, 32,   -11, 29,
    60,   41,  -23,  -34,  -64,  11,  13,  -21,  16,  -34, -16,  12,  37,
    48,   -12, -3,   59,   -55,  -35, 51,  -38,  -47, 56,  -17,  -47, -30,
    -22,  -33, 2,    -50,  31,   -38, -13, 52,   -17, -1,  -3,   2,   -30,
    23,   -37, -24,  26,   30,   48,  57,  -11,  -51, -23, 9,    43,  29,
    69,   34,  -22,  -14,  -21,  61,  -2,  -3,   -4,  31,  19,   13,  32,
    -45,  8,   47,   -35,  -20,  -85, 6,   19,   43,  14,  33,   -21, 55,
    79,   13,  78,   -53,  -93,  -20, -55, -103, -53, -84, 29,   44,  49,
    -113, -84, 15,   43,   -44,  -25, 101, 65,   2,   21,  -121, 15,  9,
    48,   -1,  -104, 18,   96,   86,  88,  -71,  98,  -27, 57,   67,  -64,
    -79,  -72, -42,  -98,  69,   15,  16,  -76,  -75, -70, -11,  46,  5,
    -21,  -93, -13,  -84,  -79,  41,  72,  -41,  38,  49,  45,   108, -42,
    -15,  17,  -78,  32,   83,   -23, -83, 33,   38,  -48, 31,   -35, 88,
    -55,  -50, 64,   -44,  52,   62,  3,   32,   23,  -83, -38,  71,  -3,
    70,   60,  -86,  -29,  -14,  10,  -31, -73,  14,  35,  -28,  27,  -78,
    -40,  -46, -50,  -12,  -3,   -52, -72, 30,   71,  -7,  -37,  61,  -3,
    83,   -2,  -65,  0,    91,   -31, 4,   21,   -29, 17,  -39,  -25, -98,
    11,   48,  68,   59,   -98,  -51, -97, 1,    -84, -47, 66,   -28, -86,
    79,   40,  -68,  -73,  23,   12,  5,   -75,  -32, -55, 16,   -80, -95,
    74,   -55, -17,  -1,   -26,  -61, 45,  -16,  33,  84,  29,   106, 18,
    -22,  103, -63,  -87,  -14,  -4,  80,  -17,  94,  -51, -48,  70,  78,
    25,   -2,  21,   85,   -13,  39,  14,  62,   -52, -90, 26,   -72, -61,
    -40,  94,  -24,  19,   17,   -12, 34,  -56,  -48, -39, -30,  96,  -10,
    -95,  -10, -75,  34,   -2,   -25, -66, -84,  -33, -89, -70,  101, 29,
    -69,  -58, 22,   -57,  -2,   4,   -12, 73,   -5,  -44, 38,   -58, -7,
    64,   2,   41,   30,   -1,   14,  -8,  -53,  -69, -26, 20,   70,  -49,
    -7,   14,  -7,   -11,  75,   -52, 12,  -18,  -62, 13,  -74,  -3,  -58,
    -42,  -16, -30,  -13,  -30,  64,  -13, -12,  -56, 78,  6,    52,  -17,
    61,   45,  32,   -28,  -54,  52,  -24, 52,   46,  31,  11,   -30, -38,
    50,   -26, -8,   -15,  -30,  -35, 34,  5,    -45, 54,  -8,   -38, -63,
    -34,  46,  12,   -58,  1,    -74, -37, 70,   -31, -45, -61,  -30, -37,
    8,    33,  41,   -21,  10,   22,  25,  -49,  -18, -5,  15,   31,  10,
    24,   25,  62,   -31,  30,   -33, 7,   67,   23,  -22, 0,    -33, 31,
    49,   -31, -32,  36,   56,   53,  0,   -32,  -41, 15,  -37,  48,  30,
    52,   44,  -47,  -13,  35,   30,  -9,  -47,  -21, 22,  35,   35,  59,
    -14,  -17, 24,   -52,  -19,  -34, -8,  39,   -50, 27,  8,    42,  -26,
    1,    6,   -46,  33,   45,   -56, -42, 40,   -7,  -35, 29,   -23, 7,
    42,   -41, 9,    -2,   30,   6,   -16, -26,  -43, 5,   32,   -26, -66,
    -27,  23,  40,   37,   -68,  43,  -26, 25,   -62, 7,   -20,  69,  58,
    58,   9,   -61,  44,   12,   1,   -33, 47,   -11, 59,  -3,   35,  -20,
    29,   -46, -41,  -53,  53,   35,  -5,  40,   40,  -33, 46,   19,  34,
    31,   35,  9,    16,   -49,  33,  -7,  -55,  -52, -60, -24,  61,  49,
    15,   20,  28,   30,   59,   -39, 60,  34,   -12, -22, -4,   -22, 33,
    57,   -21, -50,  82,   -8,   -78, -26, 101,  63,  46,  -19,  13,  11,
    79,   60,  9,    -108, -109, -11, -43, -91,  41,  88,  -103, -7,  -93,
    76,   20,  85,   -25,  58,   16,  39,  -109, -65, -33, -73,  -90, 105,
    -83,  -84, -35,  30,   92,   26,  45,  45,   88,  -42, -36,  -16, -110,
    25,   110, 62,   -11,  14,   -54, -6,  4,    107, -8,  109,  91,  -93,
    48,   -43, -17,  19,   16,   56,  -73, -51,  95,  93,  77,   -44, 110,
    -20,  33,  -75,  33,   34,   -45, -11, 51,   27,  -60, -3,   -30, 40,
    48,   2,   -33,  25,   -31,  -58, -52, 41,   7,   -18, -10,  29,  1,
    50,   -58, -16,  -53,  -8,   54,  2,   -49,  9,   27,  22,   2,   18,
    -25,  -35, -33,  -5,   -2,   52,  55,  0,    32,  52,  -16,  49,  25,
    12,   -22, 45,   20,   -58,  34,  10,  8,    -58, 9,   -14,  -48, -53,
    -8,   10,  -28,  49,   -47,  -10, 53,  43,   -6,  -38, 31,   59,  34,
    9,    22,  -13,  -13,  -60,  29,  -3,  18,   -32, -34, 40,   -2,  -36,
    -19,  -40, 67,   40,   45,   65,  25,  -14,  24,  -44, -42,  55,  33,
    59,   12,  -48,  33,   40,   15,  -32, -16,  -42, 32,  27,   -51, -13,
    -16,  27,  5,    17,   27,   38,  0,   -48,  1,   25,  30,   44,  54,
    36,   -19, -35,  -10,  -58,  13,  -41, 22,   -49, -26, -39,  -16, 12,
    52,   63,  63,   62,   31,   -46, 26,  -54,  22,  -43, 45,   63,  31,
    -16,  -18, 13,   34,   1,    59,  62,  -45,  6,   -89, -76,  -56, -55,
    61,   -82, -31,  -44,  -52,  58,  54,  90,   -59, -37, 48,   -73, -37,
    11,   51,  -99,  31,   -97,  0,   72,  -34,  61,  -49, 104,  -32, -97,
    48,   26,  85,   -51,  -96,  48,  -94, 4,    -33, -77, 4,    86,  67,
    9,    58,  68,   -3,   27,   -13, -15, 90,   15,  99,  24,   88,  -18,
    58,   75,  -30,  -94,  23,   13,  54,  -61,  -53, 80,  24,   102, -35,
    -11,  -73, 100,  36,   -82,  -4,  112, 15,   51,  -75, -32,  29,  34,
    55,   -23, 46,   -5,   11,   30,  -29, -56,  -50, -17, 2,    9,   -8,
    -13,  7,   -18,  -7,   37,   -23, 6,   -18,  34,  36,  16,   -40, -45,
    28,   33,  -48,  44,   -7,   1,   39,  -42,  53,  30,  18,   -34, 34,
    -16,  -51, -41,  -30,  -1,   -37, 39,  42,   9,   21,  14,   -34, -51,
    38,   -7,  -45,  -54,  18,   31,  3,   35,   -51, -29, -40,  38,  36,
    -39,  -35, -38,  18,   16,   -58, 39,  -34,  -47, 11,  19,   52};
static const int32_t conv2_offset[32] = {
    13953,  -5662, 3780,   -9795,  -6404, -13715, 10449, -249,
    -1089,  15299, -11308, 7075,   12512, -509,   7444,  -7447,
    -21623, 4472,  2527,   -10212, -8450, 13426,  13082, 14047,
    15081,  -9197, -11422, -8499,  -2861, -15106, -5099, 3838};
static const uint32_t conv2_shift[32] = {7, 8, 8, 8, 7, 8, 8, 8, 7, 9, 8,
                                         9, 8, 7, 8, 8, 8, 8, 8, 8, 8, 9,
                                         8, 8, 7, 8, 8, 9, 7, 8, 8, 7};

static const int8_t fc_weight[256] = {
    8,   -37, 2,   9,   -20, 36,  -40, 43,  50,  -61, 26,  -1,  29,  -68, 62,
    -51, -34, 52,  -2,  12,  3,   53,  8,   36,  7,   29,  -80, 100, -54, 36,
    22,  12,  8,   21,  6,   -38, -35, 23,  25,  27,  -21, -34, 49,  -26, 11,
    -21, 34,  -76, -28, 2,   -34, -35, -30, -28, -58, 13,  -18, -2,  54,  -42,
    82,  -68, 62,  -10, -13, 32,  61,  -38, -54, -25, -54, 0,   -39, 15,  -35,
    39,  -60, 26,  -19, 10,  -20, 2,   -62, 56,  13,  -13, 11,  23,  -13, 48,
    -68, 3,   -52, 44,  -21, 56,  -44, 43,  -18, -9,  -45, 39,  -19, 42,  2,
    -43, 44,  -17, -66, 65,  -64, 73,  -12, -41, -22, 23,  90,  -25, 58,  -42,
    31,  -13, 41,  -18, 59,  -7,  78,  -61, 35,  -51, -55, 29,  17,  38,  5,
    29,  4,   7,   -15, 61,  -45, -5,  25,  -23, -46, 14,  45,  -20, 17,  -33,
    21,  40,  43,  -36, -48, 50,  -57, 42,  -28, -12, -28, -17, 40,  15,  61,
    -71, 49,  -61, -7,  14,  50,  -29, -10, -34, 16,  -34, 41,  -28, -11, 16,
    40,  -2,  39,  -74, 12,  -4,  -22, 48,  -15, 5,   -57, 8,   26,  -42, -79,
    33,  -29, 66,  9,   -26, 11,  -18, -24, 82,  -43, -15, -29, -32, -60, 27,
    -37, 23,  -5,  56,  -20, -12, -16, -18, 18,  -12, -2,  -63, 81,  -30, 9,
    -15, -32, -5,  18,  54,  -28, 3,   59,  -26, 15,  -17, 80,  -33, 88,  -18,
    -33, 42,  1,   -6,  48,  -45, 60,  -71, 17,  15,  19,  53,  -6,  34,  -30,
    35};
static const int32_t fc_offset[2] = {2766, -1822};
static const uint32_t fc_shift[2] = {11, 11};
static const int8_t golden_output[2] = {63, -54};

static int16_t act0[RVV_CNN_TS_GEN_BASE_4K_INT8_MAX_ACT]
    __attribute__((aligned(128), section(".l2"), unused));
static int16_t act1[RVV_CNN_TS_GEN_BASE_4K_INT8_MAX_ACT]
    __attribute__((aligned(128), section(".l2"), unused));
static int32_t feature_sums[RVV_CNN_TS_GEN_BASE_4K_INT8_FC_IN]
    __attribute__((unused, aligned(128), section(".l2")));
static int8_t output[2] __attribute__((aligned(128), section(".l2")));

static inline __attribute__((always_inline)) int32_t clamp_i32(int32_t value, int32_t lo, int32_t hi) {
  if (value < lo)
    return lo;
  if (value > hi)
    return hi;
  return value;
}

static inline __attribute__((always_inline)) int32_t floor_div_pow2(int32_t value, uint32_t shift) {
  int32_t denom = 1 << shift;
  if (value >= 0)
    return value >> shift;
  return -(((-value) + denom - 1) >> shift);
}

static inline __attribute__((always_inline)) int16_t requant_u8(int32_t value, uint32_t shift) {
  return (int16_t)clamp_i32(floor_div_pow2(value, shift), 0, 255);
}

static inline __attribute__((always_inline)) int8_t requant_i8_div(int32_t numerator, int32_t denominator) {
  int32_t q = numerator / denominator;
  int32_t r = numerator % denominator;
  if (r != 0 && numerator < 0)
    --q;
  return (int8_t)clamp_i32((int32_t)q, -128, 127);
}

static inline __attribute__((always_inline)) void maxpool1d_i16(int16_t *out, const int16_t *in, uint64_t channels,
                          uint64_t in_len, uint64_t k_len, uint64_t stride,
                          uint64_t pad) {
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  if (pad == 1 && k_len == 3 && stride == 2) {
    for (uint64_t c = 0; c < channels; ++c) {
      const int16_t *in_c = in + c * in_len;
      int16_t *out_c = out + c * out_len;
      int16_t m0 = in_c[0];
      if (in_c[1] > m0)
        m0 = in_c[1];
      out_c[0] = m0;
      uint64_t t = 1;
      uint64_t avl = out_len - 1;
      while (avl > 0) {
        size_t vl = __riscv_vsetvl_e16m1(avl);
        const int16_t *p = in_c + 2 * t - 1;
        vint16m1_t left = __riscv_vlse16_v_i16m1(p, (ptrdiff_t)(2 * sizeof(int16_t)), vl);
        vint16m1_t mid = __riscv_vlse16_v_i16m1(p + 1, (ptrdiff_t)(2 * sizeof(int16_t)), vl);
        vint16m1_t right = __riscv_vlse16_v_i16m1(p + 2, (ptrdiff_t)(2 * sizeof(int16_t)), vl);
        vint16m1_t maxv = __riscv_vmax_vv_i16m1(left, mid, vl);
        maxv = __riscv_vmax_vv_i16m1(maxv, right, vl);
        __riscv_vse16_v_i16m1(out_c + t, maxv, vl);
        t += vl;
        avl -= vl;
      }
    }
    return;
  }
  if (pad == 0) {
    for (uint64_t c = 0; c < channels; ++c) {
      const int16_t *in_c = in + c * in_len;
      int16_t *out_c = out + c * out_len;
      for (uint64_t t = 0; t < out_len; ++t) {
        const int16_t *p = in_c + t * stride;
        int16_t maxv = p[0];
        for (uint64_t k = 1; k < k_len; ++k) {
          int16_t v = p[k];
          if (v > maxv)
            maxv = v;
        }
        out_c[t] = maxv;
      }
    }
    return;
  }
  for (uint64_t c = 0; c < channels; ++c) {
    for (uint64_t t = 0; t < out_len; ++t) {
      int16_t maxv = -32768;
      for (uint64_t k = 0; k < k_len; ++k) {
        int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
        if (it >= 0 && it < (int64_t)in_len) {
          int16_t v = in[c * in_len + (uint64_t)it];
          if (v > maxv)
            maxv = v;
        }
      }
      out[c * out_len + t] = maxv;
    }
  }
}

static inline __attribute__((always_inline)) void avgpool1d_i16_to_i32_sum(int32_t *out, const int16_t *in,
                                      uint64_t channels, uint64_t in_len,
                                      uint64_t k_len, uint64_t stride,
                                      uint64_t pad) {
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  for (uint64_t c = 0; c < channels; ++c) {
    const int16_t *in_c = in + c * in_len;
    int32_t *out_c = out + c * out_len;
    for (uint64_t t = 0; t < out_len; ++t) {
      int32_t sum = 0;
      for (uint64_t k = 0; k < k_len; ++k) {
        int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
        if (it >= 0 && it < (int64_t)in_len)
          sum += in_c[(uint64_t)it];
      }
      out_c[t] = sum;
    }
  }
}

static inline __attribute__((always_inline)) void copy_i16_rvv(int16_t *dst, const int16_t *src, uint64_t len) {
  while (len > 0) {
    size_t vl = __riscv_vsetvl_e16m1(len);
    vint16m1_t v = __riscv_vle16_v_i16m1(src, vl);
    __riscv_vse16_v_i16m1(dst, v, vl);
    src += vl;
    dst += vl;
    len -= vl;
  }
}



static vint16m1_t requant_u8_vec(vint32m2_t value, uint32_t shift, size_t vl) {
  vint16m1_t narrowed = __riscv_vnsra_wx_i16m1(value, shift, vl);
  narrowed = __riscv_vmax_vx_i16m1(narrowed, 0, vl);
  return __riscv_vmin_vx_i16m1(narrowed, 255, vl);
}

static void conv1d_relu_i8(int16_t *out, const int16_t *in, uint64_t in_ch,
                           uint64_t in_len, uint64_t out_ch, uint64_t k_len,
                           uint64_t stride, uint64_t pad, uint64_t group,
                           const int8_t *weight, const int32_t *offset,
                           const uint32_t *shift) {
  const uint64_t icpg = in_ch / group;
  const uint64_t ocpg = out_ch / group;
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  uint64_t first_valid = (pad + stride - 1) / stride;
  uint64_t last_valid = 0;
  if (in_len + pad >= k_len)
    last_valid = (in_len + pad - k_len) / stride;
  if (first_valid > out_len)
    first_valid = out_len;
  if (last_valid >= out_len)
    last_valid = out_len - 1;
  if (last_valid + 1 < first_valid)
    first_valid = out_len;


  uint64_t oc = 0;
  while (oc < out_ch) {
    const uint64_t g = oc / ocpg;
    const uint64_t in_base_ch = g * icpg;
    const int can_pair = (oc + 1 < out_ch) && ((oc + 1) / ocpg == g);


    if ((oc + 3 < out_ch) && ((oc + 3) / ocpg == g)) {
      const uint64_t oc1 = oc + 1;
      const uint64_t oc2 = oc + 2;
      const uint64_t oc3 = oc + 3;
      for (uint64_t t = 0; t < first_valid; ++t) {
        int32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          for (uint64_t k = 0; k < k_len; ++k) {
            int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
            if (it >= 0 && it < (int64_t)in_len) {
              const int32_t x = in[(in_base_ch + icg) * in_len + (uint64_t)it];
              uint64_t wi = (oc * icpg + icg) * k_len + k;
              s0 += x * (int32_t)weight[wi];
              s1 += x * (int32_t)weight[wi + icpg * k_len];
              s2 += x * (int32_t)weight[wi + 2 * icpg * k_len];
              s3 += x * (int32_t)weight[wi + 3 * icpg * k_len];
            }
          }
        }
        out[oc * out_len + t] = requant_u8(s0 + offset[oc], shift[oc]);
        out[oc1 * out_len + t] = requant_u8(s1 + offset[oc1], shift[oc1]);
        out[oc2 * out_len + t] = requant_u8(s2 + offset[oc2], shift[oc2]);
        out[oc3 * out_len + t] = requant_u8(s3 + offset[oc3], shift[oc3]);
      }

      uint64_t t = first_valid;
      uint64_t avl = (first_valid < out_len) ? (last_valid + 1 - first_valid) : 0;
      while (avl > 0) {
        size_t vl = __riscv_vsetvl_e16m1(avl);
        vint32m2_t acc0 = __riscv_vmv_v_x_i32m2(0, vl);
        vint32m2_t acc1 = __riscv_vmv_v_x_i32m2(0, vl);
        vint32m2_t acc2 = __riscv_vmv_v_x_i32m2(0, vl);
        vint32m2_t acc3 = __riscv_vmv_v_x_i32m2(0, vl);
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          for (uint64_t k = 0; k < k_len; ++k) {
            uint64_t first = t * stride + k - pad;
            const int16_t *ptr = in + (in_base_ch + icg) * in_len + first;
            vint16m1_t v;
            if (stride == 1)
              v = __riscv_vle16_v_i16m1(ptr, vl);
            else
              v = __riscv_vlse16_v_i16m1(ptr, (ptrdiff_t)(stride * sizeof(int16_t)), vl);
            uint64_t wi = (oc * icpg + icg) * k_len + k;
            acc0 = __riscv_vwmacc_vx_i32m2(acc0, (int16_t)weight[wi], v, vl);
            acc1 = __riscv_vwmacc_vx_i32m2(acc1, (int16_t)weight[wi + icpg * k_len], v, vl);
            acc2 = __riscv_vwmacc_vx_i32m2(acc2, (int16_t)weight[wi + 2 * icpg * k_len], v, vl);
            acc3 = __riscv_vwmacc_vx_i32m2(acc3, (int16_t)weight[wi + 3 * icpg * k_len], v, vl);
          }
        }
        acc0 = __riscv_vadd_vx_i32m2(acc0, offset[oc], vl);
        acc1 = __riscv_vadd_vx_i32m2(acc1, offset[oc1], vl);
        acc2 = __riscv_vadd_vx_i32m2(acc2, offset[oc2], vl);
        acc3 = __riscv_vadd_vx_i32m2(acc3, offset[oc3], vl);
        vint16m1_t q0 = requant_u8_vec(acc0, shift[oc], vl);
        vint16m1_t q1 = requant_u8_vec(acc1, shift[oc1], vl);
        vint16m1_t q2 = requant_u8_vec(acc2, shift[oc2], vl);
        vint16m1_t q3 = requant_u8_vec(acc3, shift[oc3], vl);
        __riscv_vse16_v_i16m1(out + oc * out_len + t, q0, vl);
        __riscv_vse16_v_i16m1(out + oc1 * out_len + t, q1, vl);
        __riscv_vse16_v_i16m1(out + oc2 * out_len + t, q2, vl);
        __riscv_vse16_v_i16m1(out + oc3 * out_len + t, q3, vl);
        t += vl;
        avl -= vl;
      }

      for (uint64_t tt = last_valid + 1; tt < out_len; ++tt) {
        int32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          for (uint64_t k = 0; k < k_len; ++k) {
            int64_t it = (int64_t)(tt * stride + k) - (int64_t)pad;
            if (it >= 0 && it < (int64_t)in_len) {
              const int32_t x = in[(in_base_ch + icg) * in_len + (uint64_t)it];
              uint64_t wi = (oc * icpg + icg) * k_len + k;
              s0 += x * (int32_t)weight[wi];
              s1 += x * (int32_t)weight[wi + icpg * k_len];
              s2 += x * (int32_t)weight[wi + 2 * icpg * k_len];
              s3 += x * (int32_t)weight[wi + 3 * icpg * k_len];
            }
          }
        }
        out[oc * out_len + tt] = requant_u8(s0 + offset[oc], shift[oc]);
        out[oc1 * out_len + tt] = requant_u8(s1 + offset[oc1], shift[oc1]);
        out[oc2 * out_len + tt] = requant_u8(s2 + offset[oc2], shift[oc2]);
        out[oc3 * out_len + tt] = requant_u8(s3 + offset[oc3], shift[oc3]);
      }
      oc += 4;
      continue;
    }

    if (can_pair) {
      const uint64_t oc1 = oc + 1;
      for (uint64_t t = 0; t < first_valid; ++t) {
        int32_t s0 = 0;
        int32_t s1 = 0;
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          for (uint64_t k = 0; k < k_len; ++k) {
            int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
            if (it >= 0 && it < (int64_t)in_len) {
              const int32_t x = in[(in_base_ch + icg) * in_len + (uint64_t)it];
              uint64_t widx0 = (oc * icpg + icg) * k_len + k;
              uint64_t widx1 = (oc1 * icpg + icg) * k_len + k;
              s0 += x * (int32_t)weight[widx0];
              s1 += x * (int32_t)weight[widx1];
            }
          }
        }
        out[oc * out_len + t] = requant_u8(s0 + offset[oc], shift[oc]);
        out[oc1 * out_len + t] = requant_u8(s1 + offset[oc1], shift[oc1]);
      }

      uint64_t t = first_valid;
      uint64_t avl = (first_valid < out_len) ? (last_valid + 1 - first_valid) : 0;
      while (avl > 0) {
        size_t vl = __riscv_vsetvl_e16m1(avl);
        vint32m2_t acc0 = __riscv_vmv_v_x_i32m2(0, vl);
        vint32m2_t acc1 = __riscv_vmv_v_x_i32m2(0, vl);
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          for (uint64_t k = 0; k < k_len; ++k) {
            uint64_t first = t * stride + k - pad;
            const int16_t *ptr = in + (in_base_ch + icg) * in_len + first;
            vint16m1_t v;
            if (stride == 1)
              v = __riscv_vle16_v_i16m1(ptr, vl);
            else
              v = __riscv_vlse16_v_i16m1(ptr, (ptrdiff_t)(stride * sizeof(int16_t)), vl);
            uint64_t widx0 = (oc * icpg + icg) * k_len + k;
            uint64_t widx1 = (oc1 * icpg + icg) * k_len + k;
            acc0 = __riscv_vwmacc_vx_i32m2(acc0, (int16_t)weight[widx0], v, vl);
            acc1 = __riscv_vwmacc_vx_i32m2(acc1, (int16_t)weight[widx1], v, vl);
          }
        }
        acc0 = __riscv_vadd_vx_i32m2(acc0, offset[oc], vl);
        acc1 = __riscv_vadd_vx_i32m2(acc1, offset[oc1], vl);
        vint16m1_t q0 = requant_u8_vec(acc0, shift[oc], vl);
        vint16m1_t q1 = requant_u8_vec(acc1, shift[oc1], vl);
        __riscv_vse16_v_i16m1(out + oc * out_len + t, q0, vl);
        __riscv_vse16_v_i16m1(out + oc1 * out_len + t, q1, vl);
        t += vl;
        avl -= vl;
      }

      for (uint64_t tt = last_valid + 1; tt < out_len; ++tt) {
        int32_t s0 = 0;
        int32_t s1 = 0;
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          for (uint64_t k = 0; k < k_len; ++k) {
            int64_t it = (int64_t)(tt * stride + k) - (int64_t)pad;
            if (it >= 0 && it < (int64_t)in_len) {
              const int32_t x = in[(in_base_ch + icg) * in_len + (uint64_t)it];
              uint64_t widx0 = (oc * icpg + icg) * k_len + k;
              uint64_t widx1 = (oc1 * icpg + icg) * k_len + k;
              s0 += x * (int32_t)weight[widx0];
              s1 += x * (int32_t)weight[widx1];
            }
          }
        }
        out[oc * out_len + tt] = requant_u8(s0 + offset[oc], shift[oc]);
        out[oc1 * out_len + tt] = requant_u8(s1 + offset[oc1], shift[oc1]);
      }
      oc += 2;
      continue;
    }

    for (uint64_t t = 0; t < first_valid; ++t) {
      int32_t s = 0;
      for (uint64_t icg = 0; icg < icpg; ++icg) {
        for (uint64_t k = 0; k < k_len; ++k) {
          int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
          if (it >= 0 && it < (int64_t)in_len) {
            uint64_t widx = (oc * icpg + icg) * k_len + k;
            s += (int32_t)in[(in_base_ch + icg) * in_len + (uint64_t)it] *
                 (int32_t)weight[widx];
          }
        }
      }
      out[oc * out_len + t] = requant_u8(s + offset[oc], shift[oc]);
    }

    uint64_t t = first_valid;
    uint64_t avl = (first_valid < out_len) ? (last_valid + 1 - first_valid) : 0;
    while (avl > 0) {
      size_t vl = __riscv_vsetvl_e16m1(avl);
      vint32m2_t acc = __riscv_vmv_v_x_i32m2(0, vl);
      for (uint64_t icg = 0; icg < icpg; ++icg) {
        for (uint64_t k = 0; k < k_len; ++k) {
          uint64_t first = t * stride + k - pad;
          const int16_t *ptr = in + (in_base_ch + icg) * in_len + first;
          vint16m1_t v;
          if (stride == 1)
            v = __riscv_vle16_v_i16m1(ptr, vl);
          else
            v = __riscv_vlse16_v_i16m1(ptr, (ptrdiff_t)(stride * sizeof(int16_t)), vl);
          uint64_t widx = (oc * icpg + icg) * k_len + k;
          acc = __riscv_vwmacc_vx_i32m2(acc, (int16_t)weight[widx], v, vl);
        }
      }
      acc = __riscv_vadd_vx_i32m2(acc, offset[oc], vl);
      vint16m1_t q = requant_u8_vec(acc, shift[oc], vl);
      __riscv_vse16_v_i16m1(out + oc * out_len + t, q, vl);
      t += vl;
      avl -= vl;
    }

    for (uint64_t tt = last_valid + 1; tt < out_len; ++tt) {
      int32_t s = 0;
      for (uint64_t icg = 0; icg < icpg; ++icg) {
        for (uint64_t k = 0; k < k_len; ++k) {
          int64_t it = (int64_t)(tt * stride + k) - (int64_t)pad;
          if (it >= 0 && it < (int64_t)in_len) {
            uint64_t widx = (oc * icpg + icg) * k_len + k;
            s += (int32_t)in[(in_base_ch + icg) * in_len + (uint64_t)it] *
                 (int32_t)weight[widx];
          }
        }
      }
      out[oc * out_len + tt] = requant_u8(s + offset[oc], shift[oc]);
    }
    ++oc;
  }
}


static uint8_t act0_u8[RVV_CNN_TS_GEN_BASE_4K_INT8_MAX_ACT]
    __attribute__((aligned(128), section(".l2")));
static uint8_t act1_u8[RVV_CNN_TS_GEN_BASE_4K_INT8_MAX_ACT]
    __attribute__((aligned(128), section(".l2")));

static inline __attribute__((always_inline)) void pack_i16_to_u8_rvv(uint8_t *dst, const int16_t *src, uint64_t len) {
  while (len > 0) {
    size_t vl = __riscv_vsetvl_e8m1(len);
    vint16m2_t v = __riscv_vle16_v_i16m2(src, vl);
    v = __riscv_vmax_vx_i16m2(v, 0, vl);
    v = __riscv_vmin_vx_i16m2(v, 255, vl);
    vuint16m2_t uv = __riscv_vreinterpret_v_i16m2_u16m2(v);
    vuint8m1_t q = __riscv_vnclipu_wx_u8m1(uv, 0, 0, vl);
    __riscv_vse8_v_u8m1(dst, q, vl);
    src += vl;
    dst += vl;
    len -= vl;
  }
}

static inline __attribute__((always_inline)) vuint8m1_t requant_u8_vec32_to_u8(vint32m4_t value, uint32_t shift, size_t vl) {
  vint16m2_t narrowed = __riscv_vnsra_wx_i16m2(value, shift, vl);
  narrowed = __riscv_vmax_vx_i16m2(narrowed, 0, vl);
  narrowed = __riscv_vmin_vx_i16m2(narrowed, 255, vl);
  vuint16m2_t u16 = __riscv_vreinterpret_v_i16m2_u16m2(narrowed);
  return __riscv_vnclipu_wx_u8m1(u16, 0, 0, vl);
}


static void conv1d_relu_s8_to_u8(uint8_t *out, const int8_t *in, uint64_t in_len,
                                 uint64_t out_ch, uint64_t k_len, uint64_t stride,
                                 uint64_t pad, const int8_t *weight,
                                 const int32_t *offset, const uint32_t *shift) {
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  uint64_t first_valid = (pad + stride - 1) / stride;
  uint64_t last_valid = 0;
  if (in_len + pad >= k_len)
    last_valid = (in_len + pad - k_len) / stride;
  if (first_valid > out_len)
    first_valid = out_len;
  if (last_valid >= out_len)
    last_valid = out_len - 1;
  if (last_valid + 1 < first_valid)
    first_valid = out_len;

  for (uint64_t oc = 0; oc < out_ch; oc += 4) {
    const uint64_t oc1 = oc + 1, oc2 = oc + 2, oc3 = oc + 3;
    for (uint64_t t = 0; t < first_valid; ++t) {
      int32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
      for (uint64_t k = 0; k < k_len; ++k) {
        int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
        if (it >= 0 && it < (int64_t)in_len) {
          int32_t x = in[(uint64_t)it];
          s0 += x * (int32_t)weight[oc * k_len + k];
          s1 += x * (int32_t)weight[oc1 * k_len + k];
          s2 += x * (int32_t)weight[oc2 * k_len + k];
          s3 += x * (int32_t)weight[oc3 * k_len + k];
        }
      }
      out[oc * out_len + t] = (uint8_t)requant_u8(s0 + offset[oc], shift[oc]);
      out[oc1 * out_len + t] = (uint8_t)requant_u8(s1 + offset[oc1], shift[oc1]);
      out[oc2 * out_len + t] = (uint8_t)requant_u8(s2 + offset[oc2], shift[oc2]);
      out[oc3 * out_len + t] = (uint8_t)requant_u8(s3 + offset[oc3], shift[oc3]);
    }
    uint64_t t = first_valid;
    uint64_t avl = (first_valid < out_len) ? (last_valid + 1 - first_valid) : 0;
    while (avl > 0) {
      size_t vl = __riscv_vsetvl_e8m1(avl);
      vint32m4_t acc0 = __riscv_vmv_v_x_i32m4(0, vl);
      vint32m4_t acc1 = __riscv_vmv_v_x_i32m4(0, vl);
      vint32m4_t acc2 = __riscv_vmv_v_x_i32m4(0, vl);
      vint32m4_t acc3 = __riscv_vmv_v_x_i32m4(0, vl);
      for (uint64_t k = 0; k < k_len; ++k) {
        uint64_t first = t * stride + k - pad;
        const int8_t *ptr = in + first;
        vint8m1_t vi8;
        if (stride == 1)
          vi8 = __riscv_vle8_v_i8m1(ptr, vl);
        else
          vi8 = __riscv_vlse8_v_i8m1(ptr, (ptrdiff_t)stride, vl);
        vint16m2_t v = __riscv_vsext_vf2_i16m2(vi8, vl);
        acc0 = __riscv_vwmacc_vx_i32m4(acc0, (int16_t)weight[oc * k_len + k], v, vl);
        acc1 = __riscv_vwmacc_vx_i32m4(acc1, (int16_t)weight[oc1 * k_len + k], v, vl);
        acc2 = __riscv_vwmacc_vx_i32m4(acc2, (int16_t)weight[oc2 * k_len + k], v, vl);
        acc3 = __riscv_vwmacc_vx_i32m4(acc3, (int16_t)weight[oc3 * k_len + k], v, vl);
      }
      acc0 = __riscv_vadd_vx_i32m4(acc0, offset[oc], vl);
      acc1 = __riscv_vadd_vx_i32m4(acc1, offset[oc1], vl);
      acc2 = __riscv_vadd_vx_i32m4(acc2, offset[oc2], vl);
      acc3 = __riscv_vadd_vx_i32m4(acc3, offset[oc3], vl);
      __riscv_vse8_v_u8m1(out + oc * out_len + t, requant_u8_vec32_to_u8(acc0, shift[oc], vl), vl);
      __riscv_vse8_v_u8m1(out + oc1 * out_len + t, requant_u8_vec32_to_u8(acc1, shift[oc1], vl), vl);
      __riscv_vse8_v_u8m1(out + oc2 * out_len + t, requant_u8_vec32_to_u8(acc2, shift[oc2], vl), vl);
      __riscv_vse8_v_u8m1(out + oc3 * out_len + t, requant_u8_vec32_to_u8(acc3, shift[oc3], vl), vl);
      t += vl;
      avl -= vl;
    }
    for (uint64_t tt = last_valid + 1; tt < out_len; ++tt) {
      int32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
      for (uint64_t k = 0; k < k_len; ++k) {
        int64_t it = (int64_t)(tt * stride + k) - (int64_t)pad;
        if (it >= 0 && it < (int64_t)in_len) {
          int32_t x = in[(uint64_t)it];
          s0 += x * (int32_t)weight[oc * k_len + k];
          s1 += x * (int32_t)weight[oc1 * k_len + k];
          s2 += x * (int32_t)weight[oc2 * k_len + k];
          s3 += x * (int32_t)weight[oc3 * k_len + k];
        }
      }
      out[oc * out_len + tt] = (uint8_t)requant_u8(s0 + offset[oc], shift[oc]);
      out[oc1 * out_len + tt] = (uint8_t)requant_u8(s1 + offset[oc1], shift[oc1]);
      out[oc2 * out_len + tt] = (uint8_t)requant_u8(s2 + offset[oc2], shift[oc2]);
      out[oc3 * out_len + tt] = (uint8_t)requant_u8(s3 + offset[oc3], shift[oc3]);
    }
  }
}

static void conv1d_relu_u8(uint8_t *out, const uint8_t *in, uint64_t in_ch,
                           uint64_t in_len, uint64_t out_ch, uint64_t k_len,
                           uint64_t stride, uint64_t pad, uint64_t group,
                           const int8_t *weight, const int32_t *offset,
                           const uint32_t *shift) {
  const uint64_t icpg = in_ch / group;
  const uint64_t ocpg = out_ch / group;
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  uint64_t first_valid = (pad + stride - 1) / stride;
  uint64_t last_valid = 0;
  if (in_len + pad >= k_len)
    last_valid = (in_len + pad - k_len) / stride;
  if (first_valid > out_len)
    first_valid = out_len;
  if (last_valid >= out_len)
    last_valid = out_len - 1;
  if (last_valid + 1 < first_valid)
    first_valid = out_len;

  if (group == 1 && stride == 2 && pad > 0) {
    uint64_t oc = 0;
    while (oc < out_ch) {
      if (oc + 3 < out_ch) {
        const uint64_t oc1 = oc + 1, oc2 = oc + 2, oc3 = oc + 3;
        for (uint64_t t = 0; t < first_valid; ++t) {
          int32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
          for (uint64_t ic = 0; ic < in_ch; ++ic) {
            for (uint64_t k = 0; k < k_len; ++k) {
              int64_t it = (int64_t)(2 * t + k) - (int64_t)pad;
              if (it >= 0 && it < (int64_t)in_len) {
                int32_t x = in[ic * in_len + (uint64_t)it];
                uint64_t wi = (oc * in_ch + ic) * k_len + k;
                s0 += x * (int32_t)weight[wi];
                s1 += x * (int32_t)weight[wi + in_ch * k_len];
                s2 += x * (int32_t)weight[wi + 2 * in_ch * k_len];
                s3 += x * (int32_t)weight[wi + 3 * in_ch * k_len];
              }
            }
          }
          out[oc * out_len + t] = (uint8_t)requant_u8(s0 + offset[oc], shift[oc]);
          out[oc1 * out_len + t] = (uint8_t)requant_u8(s1 + offset[oc1], shift[oc1]);
          out[oc2 * out_len + t] = (uint8_t)requant_u8(s2 + offset[oc2], shift[oc2]);
          out[oc3 * out_len + t] = (uint8_t)requant_u8(s3 + offset[oc3], shift[oc3]);
        }
        uint64_t t = first_valid;
        uint64_t avl = (first_valid < out_len) ? (last_valid + 1 - first_valid) : 0;
        while (avl > 0) {
          size_t vl = __riscv_vsetvl_e8m1(avl);
          vint32m4_t acc0 = __riscv_vmv_v_x_i32m4(0, vl);
          vint32m4_t acc1 = __riscv_vmv_v_x_i32m4(0, vl);
          vint32m4_t acc2 = __riscv_vmv_v_x_i32m4(0, vl);
          vint32m4_t acc3 = __riscv_vmv_v_x_i32m4(0, vl);
          for (uint64_t ic = 0; ic < in_ch; ++ic) {
            for (uint64_t k = 0; k < k_len; ++k) {
              const uint8_t *ptr = in + ic * in_len + 2 * t + k - pad;
              vuint8m1_t vu8 = __riscv_vlse8_v_u8m1(ptr, 2, vl);
              vuint16m2_t vu16 = __riscv_vzext_vf2_u16m2(vu8, vl);
              vint16m2_t v = __riscv_vreinterpret_v_u16m2_i16m2(vu16);
              uint64_t wi = (oc * in_ch + ic) * k_len + k;
              acc0 = __riscv_vwmacc_vx_i32m4(acc0, (int16_t)weight[wi], v, vl);
              acc1 = __riscv_vwmacc_vx_i32m4(acc1, (int16_t)weight[wi + in_ch * k_len], v, vl);
              acc2 = __riscv_vwmacc_vx_i32m4(acc2, (int16_t)weight[wi + 2 * in_ch * k_len], v, vl);
              acc3 = __riscv_vwmacc_vx_i32m4(acc3, (int16_t)weight[wi + 3 * in_ch * k_len], v, vl);
            }
          }
          acc0 = __riscv_vadd_vx_i32m4(acc0, offset[oc], vl);
          acc1 = __riscv_vadd_vx_i32m4(acc1, offset[oc1], vl);
          acc2 = __riscv_vadd_vx_i32m4(acc2, offset[oc2], vl);
          acc3 = __riscv_vadd_vx_i32m4(acc3, offset[oc3], vl);
          __riscv_vse8_v_u8m1(out + oc * out_len + t, requant_u8_vec32_to_u8(acc0, shift[oc], vl), vl);
          __riscv_vse8_v_u8m1(out + oc1 * out_len + t, requant_u8_vec32_to_u8(acc1, shift[oc1], vl), vl);
          __riscv_vse8_v_u8m1(out + oc2 * out_len + t, requant_u8_vec32_to_u8(acc2, shift[oc2], vl), vl);
          __riscv_vse8_v_u8m1(out + oc3 * out_len + t, requant_u8_vec32_to_u8(acc3, shift[oc3], vl), vl);
          t += vl;
          avl -= vl;
        }
        for (uint64_t tt = last_valid + 1; tt < out_len; ++tt) {
          int32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
          for (uint64_t ic = 0; ic < in_ch; ++ic) {
            for (uint64_t k = 0; k < k_len; ++k) {
              int64_t it = (int64_t)(2 * tt + k) - (int64_t)pad;
              if (it >= 0 && it < (int64_t)in_len) {
                int32_t x = in[ic * in_len + (uint64_t)it];
                uint64_t wi = (oc * in_ch + ic) * k_len + k;
                s0 += x * (int32_t)weight[wi];
                s1 += x * (int32_t)weight[wi + in_ch * k_len];
                s2 += x * (int32_t)weight[wi + 2 * in_ch * k_len];
                s3 += x * (int32_t)weight[wi + 3 * in_ch * k_len];
              }
            }
          }
          out[oc * out_len + tt] = (uint8_t)requant_u8(s0 + offset[oc], shift[oc]);
          out[oc1 * out_len + tt] = (uint8_t)requant_u8(s1 + offset[oc1], shift[oc1]);
          out[oc2 * out_len + tt] = (uint8_t)requant_u8(s2 + offset[oc2], shift[oc2]);
          out[oc3 * out_len + tt] = (uint8_t)requant_u8(s3 + offset[oc3], shift[oc3]);
        }
        oc += 4;
        continue;
      }
      for (uint64_t t = 0; t < out_len; ++t) {
        int32_t s = 0;
        for (uint64_t ic = 0; ic < in_ch; ++ic) {
          for (uint64_t k = 0; k < k_len; ++k) {
            int64_t it = (int64_t)(2 * t + k) - (int64_t)pad;
            if (it >= 0 && it < (int64_t)in_len)
              s += (int32_t)in[ic * in_len + (uint64_t)it] * (int32_t)weight[(oc * in_ch + ic) * k_len + k];
          }
        }
        out[oc * out_len + t] = (uint8_t)requant_u8(s + offset[oc], shift[oc]);
      }
      ++oc;
    }
    return;
  }



  if (group == out_ch && icpg == 1 && ocpg == 1) {
    for (uint64_t oc = 0; oc < out_ch; ++oc) {
      const uint8_t *in_c = in + oc * in_len;
      uint8_t *out_c = out + oc * out_len;
      for (uint64_t t = 0; t < first_valid; ++t) {
        int32_t s = 0;
        for (uint64_t k = 0; k < k_len; ++k) {
          int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
          if (it >= 0 && it < (int64_t)in_len)
            s += (int32_t)in_c[(uint64_t)it] * (int32_t)weight[oc * k_len + k];
        }
        out_c[t] = (uint8_t)requant_u8(s + offset[oc], shift[oc]);
      }
      uint64_t t = first_valid;
      uint64_t avl = (first_valid < out_len) ? (last_valid + 1 - first_valid) : 0;
      while (avl > 0) {
        size_t vl = __riscv_vsetvl_e8m1(avl);
        vint32m4_t acc = __riscv_vmv_v_x_i32m4(0, vl);
        for (uint64_t k = 0; k < k_len; ++k) {
          uint64_t first = t * stride + k - pad;
          const uint8_t *ptr = in_c + first;
          vuint8m1_t vu8;
          if (stride == 1)
            vu8 = __riscv_vle8_v_u8m1(ptr, vl);
          else
            vu8 = __riscv_vlse8_v_u8m1(ptr, (ptrdiff_t)stride, vl);
          vuint16m2_t vu16 = __riscv_vzext_vf2_u16m2(vu8, vl);
          vint16m2_t v = __riscv_vreinterpret_v_u16m2_i16m2(vu16);
          acc = __riscv_vwmacc_vx_i32m4(acc, (int16_t)weight[oc * k_len + k], v, vl);
        }
        acc = __riscv_vadd_vx_i32m4(acc, offset[oc], vl);
        __riscv_vse8_v_u8m1(out_c + t, requant_u8_vec32_to_u8(acc, shift[oc], vl), vl);
        t += vl;
        avl -= vl;
      }
      for (uint64_t tt = last_valid + 1; tt < out_len; ++tt) {
        int32_t s = 0;
        for (uint64_t k = 0; k < k_len; ++k) {
          int64_t it = (int64_t)(tt * stride + k) - (int64_t)pad;
          if (it >= 0 && it < (int64_t)in_len)
            s += (int32_t)in_c[(uint64_t)it] * (int32_t)weight[oc * k_len + k];
        }
        out_c[tt] = (uint8_t)requant_u8(s + offset[oc], shift[oc]);
      }
    }
    return;
  }

  uint64_t oc = 0;
  while (oc < out_ch) {
    const uint64_t g = oc / ocpg;
    const uint64_t in_base_ch = g * icpg;
    if ((oc + 3 < out_ch) && ((oc + 3) / ocpg == g)) {
      const uint64_t oc1 = oc + 1, oc2 = oc + 2, oc3 = oc + 3;
      for (uint64_t t = 0; t < first_valid; ++t) {
        int32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          for (uint64_t k = 0; k < k_len; ++k) {
            int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
            if (it >= 0 && it < (int64_t)in_len) {
              int32_t x = in[(in_base_ch + icg) * in_len + (uint64_t)it];
              uint64_t wi = (oc * icpg + icg) * k_len + k;
              s0 += x * (int32_t)weight[wi];
              s1 += x * (int32_t)weight[wi + icpg * k_len];
              s2 += x * (int32_t)weight[wi + 2 * icpg * k_len];
              s3 += x * (int32_t)weight[wi + 3 * icpg * k_len];
            }
          }
        }
        out[oc * out_len + t] = (uint8_t)requant_u8(s0 + offset[oc], shift[oc]);
        out[oc1 * out_len + t] = (uint8_t)requant_u8(s1 + offset[oc1], shift[oc1]);
        out[oc2 * out_len + t] = (uint8_t)requant_u8(s2 + offset[oc2], shift[oc2]);
        out[oc3 * out_len + t] = (uint8_t)requant_u8(s3 + offset[oc3], shift[oc3]);
      }
      uint64_t t = first_valid;
      uint64_t avl = (first_valid < out_len) ? (last_valid + 1 - first_valid) : 0;
      while (avl > 0) {
        size_t vl = __riscv_vsetvl_e8m1(avl);
        vint32m4_t acc0 = __riscv_vmv_v_x_i32m4(0, vl);
        vint32m4_t acc1 = __riscv_vmv_v_x_i32m4(0, vl);
        vint32m4_t acc2 = __riscv_vmv_v_x_i32m4(0, vl);
        vint32m4_t acc3 = __riscv_vmv_v_x_i32m4(0, vl);
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          for (uint64_t k = 0; k < k_len; ++k) {
            uint64_t first = t * stride + k - pad;
            const uint8_t *ptr = in + (in_base_ch + icg) * in_len + first;
            vuint8m1_t vu8;
            if (stride == 1)
              vu8 = __riscv_vle8_v_u8m1(ptr, vl);
            else
              vu8 = __riscv_vlse8_v_u8m1(ptr, (ptrdiff_t)stride, vl);
            vuint16m2_t vu16 = __riscv_vzext_vf2_u16m2(vu8, vl);
            vint16m2_t v = __riscv_vreinterpret_v_u16m2_i16m2(vu16);
            uint64_t wi = (oc * icpg + icg) * k_len + k;
            acc0 = __riscv_vwmacc_vx_i32m4(acc0, (int16_t)weight[wi], v, vl);
            acc1 = __riscv_vwmacc_vx_i32m4(acc1, (int16_t)weight[wi + icpg * k_len], v, vl);
            acc2 = __riscv_vwmacc_vx_i32m4(acc2, (int16_t)weight[wi + 2 * icpg * k_len], v, vl);
            acc3 = __riscv_vwmacc_vx_i32m4(acc3, (int16_t)weight[wi + 3 * icpg * k_len], v, vl);
          }
        }
        acc0 = __riscv_vadd_vx_i32m4(acc0, offset[oc], vl);
        acc1 = __riscv_vadd_vx_i32m4(acc1, offset[oc1], vl);
        acc2 = __riscv_vadd_vx_i32m4(acc2, offset[oc2], vl);
        acc3 = __riscv_vadd_vx_i32m4(acc3, offset[oc3], vl);
        __riscv_vse8_v_u8m1(out + oc * out_len + t, requant_u8_vec32_to_u8(acc0, shift[oc], vl), vl);
        __riscv_vse8_v_u8m1(out + oc1 * out_len + t, requant_u8_vec32_to_u8(acc1, shift[oc1], vl), vl);
        __riscv_vse8_v_u8m1(out + oc2 * out_len + t, requant_u8_vec32_to_u8(acc2, shift[oc2], vl), vl);
        __riscv_vse8_v_u8m1(out + oc3 * out_len + t, requant_u8_vec32_to_u8(acc3, shift[oc3], vl), vl);
        t += vl;
        avl -= vl;
      }
      for (uint64_t tt = last_valid + 1; tt < out_len; ++tt) {
        int32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
        for (uint64_t icg = 0; icg < icpg; ++icg) {
          for (uint64_t k = 0; k < k_len; ++k) {
            int64_t it = (int64_t)(tt * stride + k) - (int64_t)pad;
            if (it >= 0 && it < (int64_t)in_len) {
              int32_t x = in[(in_base_ch + icg) * in_len + (uint64_t)it];
              uint64_t wi = (oc * icpg + icg) * k_len + k;
              s0 += x * (int32_t)weight[wi];
              s1 += x * (int32_t)weight[wi + icpg * k_len];
              s2 += x * (int32_t)weight[wi + 2 * icpg * k_len];
              s3 += x * (int32_t)weight[wi + 3 * icpg * k_len];
            }
          }
        }
        out[oc * out_len + tt] = (uint8_t)requant_u8(s0 + offset[oc], shift[oc]);
        out[oc1 * out_len + tt] = (uint8_t)requant_u8(s1 + offset[oc1], shift[oc1]);
        out[oc2 * out_len + tt] = (uint8_t)requant_u8(s2 + offset[oc2], shift[oc2]);
        out[oc3 * out_len + tt] = (uint8_t)requant_u8(s3 + offset[oc3], shift[oc3]);
      }
      oc += 4;
      continue;
    }
    for (uint64_t t = 0; t < out_len; ++t) {
      int32_t s = 0;
      for (uint64_t icg = 0; icg < icpg; ++icg) {
        for (uint64_t k = 0; k < k_len; ++k) {
          int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
          if (it >= 0 && it < (int64_t)in_len) {
            uint64_t wi = (oc * icpg + icg) * k_len + k;
            s += (int32_t)in[(in_base_ch + icg) * in_len + (uint64_t)it] * (int32_t)weight[wi];
          }
        }
      }
      out[oc * out_len + t] = (uint8_t)requant_u8(s + offset[oc], shift[oc]);
    }
    ++oc;
  }
}

static inline __attribute__((always_inline)) void maxpool1d_u8(uint8_t *out, const uint8_t *in, uint64_t channels,
                           uint64_t in_len, uint64_t k_len, uint64_t stride,
                           uint64_t pad) {
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  if (pad == 1 && k_len == 3 && stride == 2) {
    for (uint64_t c = 0; c < channels; ++c) {
      const uint8_t *in_c = in + c * in_len;
      uint8_t *out_c = out + c * out_len;
      out_c[0] = in_c[0] > in_c[1] ? in_c[0] : in_c[1];
      uint64_t t = 1;
      uint64_t avl = out_len - 1;
      while (avl > 0) {
        size_t vl = __riscv_vsetvl_e8m1(avl);
        const uint8_t *p = in_c + 2 * t - 1;
        vuint8m1_t left = __riscv_vlse8_v_u8m1(p, 2, vl);
        vuint8m1_t mid = __riscv_vlse8_v_u8m1(p + 1, 2, vl);
        vuint8m1_t right = __riscv_vlse8_v_u8m1(p + 2, 2, vl);
        vuint8m1_t maxv = __riscv_vmaxu_vv_u8m1(left, mid, vl);
        maxv = __riscv_vmaxu_vv_u8m1(maxv, right, vl);
        __riscv_vse8_v_u8m1(out_c + t, maxv, vl);
        t += vl;
        avl -= vl;
      }
    }
    return;
  }
  for (uint64_t c = 0; c < channels; ++c) {
    for (uint64_t t = 0; t < out_len; ++t) {
      uint8_t maxv = 0;
      for (uint64_t k = 0; k < k_len; ++k) {
        int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
        if (it >= 0 && it < (int64_t)in_len) {
          uint8_t v = in[c * in_len + (uint64_t)it];
          if (v > maxv)
            maxv = v;
        }
      }
      out[c * out_len + t] = maxv;
    }
  }
}


static inline __attribute__((always_inline)) void avgpool1d_u8_to_i32_sum(int32_t *out, const uint8_t *in,
                                      uint64_t channels, uint64_t in_len,
                                      uint64_t k_len, uint64_t stride,
                                      uint64_t pad) {
  const uint64_t out_len = (in_len + 2 * pad - k_len) / stride + 1;
  for (uint64_t c = 0; c < channels; ++c) {
    for (uint64_t t = 0; t < out_len; ++t) {
      int32_t sum = 0;
      for (uint64_t k = 0; k < k_len; ++k) {
        int64_t it = (int64_t)(t * stride + k) - (int64_t)pad;
        if (it >= 0 && it < (int64_t)in_len)
          sum += in[c * in_len + (uint64_t)it];
      }
      out[c * out_len + t] = sum;
    }
  }
}

static inline __attribute__((always_inline)) void avgpool1d_linear_i8_fused(int8_t *out, const uint8_t *in,
                                                                  uint64_t channels, uint64_t in_len,
                                                                  uint64_t k_len, uint64_t stride,
                                                                  int32_t pool_count) {
  const uint64_t out_len = (in_len - k_len) / stride + 1;
  int32_t acc0 = fc_offset[0] * pool_count;
  int32_t acc1 = fc_offset[1] * pool_count;
  for (uint64_t c = 0; c < channels; ++c) {
    const uint8_t *in_c = in + c * in_len;
    for (uint64_t t = 0; t < out_len; ++t) {
      int32_t sum = 0;
      const uint8_t *p = in_c + t * stride;
      for (uint64_t k = 0; k < k_len; ++k)
        sum += p[k];
      uint64_t wi = (c * out_len + t) * 2;
      acc0 += sum * (int32_t)fc_weight[wi];
      acc1 += sum * (int32_t)fc_weight[wi + 1];
    }
  }
  out[0] = requant_i8_div(acc0, pool_count << fc_shift[0]);
  out[1] = requant_i8_div(acc1, pool_count << fc_shift[1]);
}

static inline __attribute__((always_inline)) void linear_i8_from_avg_sums(int8_t *out, const int32_t *in,
                                             int32_t pool_count) {
  for (uint64_t o = 0; o < 2; ++o) {
    int32_t acc = fc_offset[o] * pool_count;
    for (uint64_t i = 0; i < RVV_CNN_TS_GEN_BASE_4K_INT8_FC_IN; ++i)
      acc += in[i] * (int32_t)fc_weight[i * 2 + o];
    out[o] = requant_i8_div(acc, pool_count << fc_shift[o]);
  }
}

void rvv_cnn_ts_gen_base_4k_int8(void) {
  conv1d_relu_s8_to_u8(act0_u8, input_q, 256, 8, 7, 2, 3, conv0_weight, conv0_offset, conv0_shift);
  uint8_t *u = act0_u8;
  uint8_t *v = act1_u8;
  uint8_t *utmp;
  maxpool1d_u8(v, u, 8, 128, 3, 2, 1);
  utmp = u; u = v; v = utmp;
  conv1d_relu_u8(v, u, 8, 64, 16, 5, 2, 2, 1, conv1_weight, conv1_offset,
                 conv1_shift);
  utmp = u; u = v; v = utmp;
  conv1d_relu_u8(v, u, 16, 32, 32, 5, 2, 2, 1, conv2_weight, conv2_offset,
                 conv2_shift);
  utmp = u; u = v; v = utmp;
  avgpool1d_linear_i8_fused(output, u, 32, 16, 4, 4, 4);
}

const int8_t *rvv_cnn_ts_gen_base_4k_int8_output(void) { return output; }
const int8_t *rvv_cnn_ts_gen_base_4k_int8_golden_output(void) {
  return golden_output;
}

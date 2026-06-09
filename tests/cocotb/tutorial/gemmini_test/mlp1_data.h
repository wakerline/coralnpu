#ifndef TESTS_COCOTB_TUTORIAL_GEMMINI_PORT_MLP1_DATA_H_
#define TESTS_COCOTB_TUTORIAL_GEMMINI_PORT_MLP1_DATA_H_

// 先做一个最小 smoke case：16 -> 12 -> 8
// 后面再替换成从 gemmini-rocc-tests/mlps/parameters1.h
// 提炼出来的真实维度。

#define MLP1_IN_DIM 16
#define MLP1_HIDDEN_DIM 12
#define MLP1_OUT_DIM 8

#define MLP1_INPUT_SIZE   (MLP1_IN_DIM)
#define MLP1_W0_SIZE      (MLP1_HIDDEN_DIM * MLP1_IN_DIM)
#define MLP1_B0_SIZE      (MLP1_HIDDEN_DIM)
#define MLP1_W1_SIZE      (MLP1_OUT_DIM * MLP1_HIDDEN_DIM)
#define MLP1_B1_SIZE      (MLP1_OUT_DIM)
#define MLP1_OUTPUT_SIZE  (MLP1_OUT_DIM)

#endif  // TESTS_COCOTB_TUTORIAL_GEMMINI_PORT_MLP1_DATA_H_
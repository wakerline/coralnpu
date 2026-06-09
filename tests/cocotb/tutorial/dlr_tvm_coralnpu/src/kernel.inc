extern "C" int32_t tvmgen_default_fused_multiply_add_floor_clip_layout_transform(void* args, void* arg_type_ids, int32_t num_args);
extern "C" int32_t tvmgen_default_fused_nn_contrib_conv2d_NCHWc_multiply_add_floor_clip_nn_relu_clip(void* args, void* arg_type_ids, int32_t num_args);
extern "C" int32_t tvmgen_default_fused_nn_contrib_conv2d_NCHWc_multiply_add_floor_clip_nn_relu_clip_1(void* args, void* arg_type_ids, int32_t num_args);
extern "C" int32_t tvmgen_default_fused_nn_max_pool2d(void* args, void* arg_type_ids, int32_t num_args);
extern "C" int32_t tvmgen_default_fused_nn_contrib_conv2d_NCHWc_multiply_add_floor_clip_nn_relu_clip_2(void* args, void* arg_type_ids, int32_t num_args);
extern "C" int32_t tvmgen_default_fused_nn_avg_pool2d(void* args, void* arg_type_ids, int32_t num_args);
extern "C" int32_t tvmgen_default_fused_layout_transform_reshape(void* args, void* arg_type_ids, int32_t num_args);
extern "C" int32_t tvmgen_default_fused_nn_contrib_dense_pack_multiply_add_floor_clip(void* args, void* arg_type_ids, int32_t num_args);

void dlr::DLR::Run()
{
    int32_t ret;
    ret = tvmgen_default_fused_multiply_add_floor_clip_layout_transform(opa[0].values, opa[0].tcodes, opa[0].num);
    assert(ret == 0);
    ret = tvmgen_default_fused_nn_contrib_conv2d_NCHWc_multiply_add_floor_clip_nn_relu_clip(opa[1].values, opa[1].tcodes, opa[1].num);
    assert(ret == 0);
    ret = tvmgen_default_fused_nn_contrib_conv2d_NCHWc_multiply_add_floor_clip_nn_relu_clip_1(opa[2].values, opa[2].tcodes, opa[2].num);
    assert(ret == 0);
    ret = tvmgen_default_fused_nn_max_pool2d(opa[3].values, opa[3].tcodes, opa[3].num);
    assert(ret == 0);
    ret = tvmgen_default_fused_nn_contrib_conv2d_NCHWc_multiply_add_floor_clip_nn_relu_clip_2(opa[4].values, opa[4].tcodes, opa[4].num);
    assert(ret == 0);
    ret = tvmgen_default_fused_nn_avg_pool2d(opa[5].values, opa[5].tcodes, opa[5].num);
    assert(ret == 0);
    ret = tvmgen_default_fused_layout_transform_reshape(opa[6].values, opa[6].tcodes, opa[6].num);
    assert(ret == 0);
    ret = tvmgen_default_fused_nn_contrib_dense_pack_multiply_add_floor_clip(opa[7].values, opa[7].tcodes, opa[7].num);
    assert(ret == 0);
}


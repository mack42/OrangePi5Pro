/*
 * orangepi-npu-benchmark — minimal, dependency-free RKNPU throughput probe.
 *
 * Loads librknnrt + a .rknn model, runs N inferences on zeroed input, and
 * reports per-inference latency and throughput. No image decode, no OpenCV —
 * the point is to measure the NPU runtime path end to end, not classify.
 *
 * Usage: orangepi-npu-benchmark [model.rknn] [loops] [core_mask]
 *   model     default /usr/local/share/rknn-benchmark/mobilenet_v1.rknn
 *   loops     default 100
 *   core_mask 0=auto 1=core0 2=core1 4=core2 7=all three (needs multi-core DT)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "rknn_api.h"

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv)
{
	const char *model = argc > 1 ? argv[1]
		: "/usr/local/share/rknn-benchmark/mobilenet_v1.rknn";
	int loops = argc > 2 ? atoi(argv[2]) : 100;
	uint32_t core_mask = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : 0;
	rknn_context ctx = 0;
	rknn_sdk_version ver;
	rknn_input_output_num io;
	rknn_tensor_attr in_attr;
	rknn_input input;
	rknn_output *outs;
	unsigned char *indata;
	size_t inbytes;
	long sz;
	void *buf;
	FILE *fp;
	int ret;
	double t0, t;

	fp = fopen(model, "rb");
	if (!fp) {
		perror(model);
		return 1;
	}
	fseek(fp, 0, SEEK_END);
	sz = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	buf = malloc(sz);
	if (fread(buf, 1, sz, fp) != (size_t)sz) {
		fprintf(stderr, "short read on model\n");
		return 1;
	}
	fclose(fp);

	ret = rknn_init(&ctx, buf, sz, 0, NULL);
	free(buf);
	if (ret < 0) {
		printf("rknn_init failed: %d (is /dev/rknpu accessible?)\n", ret);
		return 1;
	}

	if (core_mask) {
		ret = rknn_set_core_mask(ctx, (rknn_core_mask)core_mask);
		if (ret < 0)
			printf("warning: set_core_mask(0x%x) failed: %d\n",
			       core_mask, ret);
	}

	memset(&ver, 0, sizeof(ver));
	rknn_query(ctx, RKNN_QUERY_SDK_VERSION, &ver, sizeof(ver));
	printf("librknnrt api : %s\n", ver.api_version);
	printf("npu driver    : %s\n", ver.drv_version);

	memset(&io, 0, sizeof(io));
	rknn_query(ctx, RKNN_QUERY_IN_OUT_NUM, &io, sizeof(io));

	memset(&in_attr, 0, sizeof(in_attr));
	in_attr.index = 0;
	rknn_query(ctx, RKNN_QUERY_INPUT_ATTR, &in_attr, sizeof(in_attr));

	inbytes = in_attr.size_with_stride > in_attr.size ?
		in_attr.size_with_stride : in_attr.size;
	if (!inbytes)
		inbytes = in_attr.n_elems;
	indata = calloc(1, inbytes);

	memset(&input, 0, sizeof(input));
	input.index = 0;
	input.type = RKNN_TENSOR_UINT8;
	input.fmt = RKNN_TENSOR_NHWC;
	input.size = in_attr.n_elems ? in_attr.n_elems : inbytes;
	input.buf = indata;

	outs = calloc(io.n_output, sizeof(*outs));

	/* warmup */
	rknn_inputs_set(ctx, 1, &input);
	rknn_run(ctx, NULL);
	for (uint32_t k = 0; k < io.n_output; k++)
		outs[k].want_float = 1;
	rknn_outputs_get(ctx, io.n_output, outs, NULL);
	rknn_outputs_release(ctx, io.n_output, outs);

	t0 = now_ms();
	for (int i = 0; i < loops; i++) {
		rknn_inputs_set(ctx, 1, &input);
		rknn_run(ctx, NULL);
		for (uint32_t k = 0; k < io.n_output; k++)
			outs[k].want_float = 1;
		rknn_outputs_get(ctx, io.n_output, outs, NULL);
		rknn_outputs_release(ctx, io.n_output, outs);
	}
	t = now_ms() - t0;

	printf("model         : %s\n", model);
	printf("inputs/outputs: %u / %u\n", io.n_input, io.n_output);
	printf("core mask     : 0x%x %s\n", core_mask,
	       core_mask ? "" : "(auto)");
	printf("loops         : %d\n", loops);
	printf("avg latency   : %.2f ms\n", t / loops);
	printf("throughput    : %.1f inferences/s\n", loops * 1000.0 / t);

	rknn_destroy(ctx);
	free(indata);
	free(outs);
	return 0;
}

// SPDX-License-Identifier: GPL-2.0
/*
 * npu_pclk_hold — diagnostic module for RK3588.
 *
 * Grabs and holds the NPU-subsystem housekeeping clocks straight from
 * the CRU provider so that TF-A's SCMI CLK_NPU set_rate (which programs
 * the NPU PVTPLL through the NPU GRF over APB) cannot dead-lock at EL3
 * against a gated pclk. Mainline gates pclk_npu_root as "unused" at
 * boot; the vendor BSP holds PCLK_NPU_ROOT in the rknpu node ("pclk")
 * and additionally force-enables PCLK_NPU_GRF + HCLK_NPU_ROOT around
 * every OPP transition (rockchip,opp-clocks).
 *
 * Default clock ids (dt-bindings/clock/rockchip,rk3588-cru.h):
 *   291 PCLK_NPU_ROOT, 284 PCLK_NPU_GRF, 283 PCLK_NPU_PVTM,
 *   285 CLK_NPU_PVTM, 286 CLK_CORE_NPU_PVTM, 289 HCLK_NPU_ROOT
 */
#include <linux/module.h>
#include <linux/clk.h>
#include <linux/clk-provider.h>
#include <linux/of.h>

#define MAX_IDS 8

static int ids[MAX_IDS] = { 291, 284, 283, 285, 286, 289 };
static int nids = 6;
module_param_array(ids, int, &nids, 0444);
MODULE_PARM_DESC(ids, "rk3588-cru clock ids to hold enabled");

static struct clk *clks[MAX_IDS];

static int __init npu_pclk_hold_init(void)
{
	struct device_node *np;
	int i;

	np = of_find_compatible_node(NULL, NULL, "rockchip,rk3588-cru");
	if (!np) {
		pr_err("npu_pclk_hold: no rk3588-cru node\n");
		return -ENODEV;
	}

	for (i = 0; i < nids; i++) {
		struct of_phandle_args a = {
			.np = np, .args_count = 1, .args = { ids[i] },
		};
		struct clk *c = of_clk_get_from_provider(&a);

		if (IS_ERR(c)) {
			pr_err("npu_pclk_hold: id %d: %ld\n", ids[i],
			       PTR_ERR(c));
			continue;
		}
		if (clk_prepare_enable(c)) {
			pr_err("npu_pclk_hold: id %d: enable failed\n",
			       ids[i]);
			clk_put(c);
			continue;
		}
		clks[i] = c;
		pr_info("npu_pclk_hold: holding id %d (%s), rate %lu\n",
			ids[i], __clk_get_name(c), clk_get_rate(c));
	}
	of_node_put(np);
	return 0;
}

static void __exit npu_pclk_hold_exit(void)
{
	int i;

	for (i = nids - 1; i >= 0; i--) {
		if (clks[i]) {
			clk_disable_unprepare(clks[i]);
			clk_put(clks[i]);
		}
	}
}

module_init(npu_pclk_hold_init);
module_exit(npu_pclk_hold_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hold RK3588 NPU housekeeping clocks for SCMI DVFS diagnostics");

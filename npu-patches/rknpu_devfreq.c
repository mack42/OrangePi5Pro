// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) Rockchip Electronics Co., Ltd.
 * Author: Finley Xiao <finley.xiao@rock-chips.com>
 *
 * Rewritten for mainline kernel (out-of-tree module) using standard
 * Linux devfreq / OPP APIs.  All Rockchip-private helpers
 * (rockchip_opp_select, rockchip_system_monitor, rockchip_ipa, etc.)
 * have been removed.
 */

#include <linux/clk.h>
#include <linux/devfreq.h>
#include <linux/devfreq-governor.h>
#include <linux/of.h>
#include <linux/pm_opp.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>
#include <linux/version.h>

#include "rknpu_drv.h"
#include "rknpu_devfreq.h"

/* ------------------------------------------------------------------ */
/*  Custom "rknpu_ondemand" governor                                  */
/*                                                                    */
/*  The driver sets rknpu_dev->ondemand_freq whenever a job is        */
/*  submitted (ramp up) or the idle timer fires (ramp down).          */
/*  The governor simply forwards that frequency to the devfreq core.  */
/* ------------------------------------------------------------------ */

static int devfreq_rknpu_ondemand_func(struct devfreq *df,
				       unsigned long *freq)
{
	struct rknpu_device *rknpu_dev = df->data;

	if (rknpu_dev && rknpu_dev->ondemand_freq)
		*freq = rknpu_dev->ondemand_freq;
	else
		*freq = df->previous_freq;

	return 0;
}

static int devfreq_rknpu_ondemand_handler(struct devfreq *devfreq,
					  unsigned int event, void *data)
{
	return 0;
}

static struct devfreq_governor devfreq_rknpu_ondemand = {
	.name = "rknpu_ondemand",
	.get_target_freq = devfreq_rknpu_ondemand_func,
	.event_handler = devfreq_rknpu_ondemand_handler,
};

/* ------------------------------------------------------------------ */
/*  devfreq profile callbacks                                         */
/* ------------------------------------------------------------------ */

static int npu_devfreq_target(struct device *dev, unsigned long *freq,
			      u32 flags)
{
	struct rknpu_device *rknpu_dev = dev_get_drvdata(dev);
	struct dev_pm_opp *opp;
	unsigned long opp_volt;
	int ret;

	opp = devfreq_recommended_opp(dev, freq, flags);
	if (IS_ERR(opp))
		return PTR_ERR(opp);
	opp_volt = dev_pm_opp_get_voltage(opp);
	dev_pm_opp_put(opp);

	if (*freq == rknpu_dev->current_freq)
		return 0;

	mutex_lock(&rknpu_dev->devfreq_lock);
	/*
	 * TF-A's SCMI CLK_NPU set_rate programs the NPU PVTPLL through
	 * the NPU GRF (APB). If the NPU housekeeping clocks (notably
	 * pclk_npu_root -> pclk_npu_grf) are gated when the SMC is
	 * issued, the EL3 register access stalls the interconnect and
	 * hard-wedges the SoC. The DT lists them in our clock bulk
	 * (vendor DTs hold "pclk" = PCLK_NPU_ROOT the same way); make
	 * sure they are running for the duration of the rate change,
	 * whatever power state the NPU is in.
	 */
	ret = clk_bulk_prepare_enable(rknpu_dev->num_clks, rknpu_dev->clks);
	if (ret) {
		mutex_unlock(&rknpu_dev->devfreq_lock);
		return ret;
	}
	ret = dev_pm_opp_set_rate(dev, *freq);
	clk_bulk_disable_unprepare(rknpu_dev->num_clks, rknpu_dev->clks);
	if (!ret) {
		rknpu_dev->current_freq = *freq;
		if (rknpu_dev->devfreq)
			rknpu_dev->devfreq->last_status.current_frequency =
				*freq;
		rknpu_dev->current_volt = opp_volt;
		LOG_DEV_DEBUG(dev, "set rknpu freq: %lu, volt: %lu\n",
			      rknpu_dev->current_freq,
			      rknpu_dev->current_volt);
	}
	mutex_unlock(&rknpu_dev->devfreq_lock);

	return ret;
}

static int npu_devfreq_get_dev_status(struct device *dev,
				      struct devfreq_dev_status *stat)
{
	struct rknpu_device *rknpu_dev = dev_get_drvdata(dev);
	struct rknpu_subcore_data *subcore_data;
	unsigned long flags;
	ktime_t busy = 0;

	stat->current_frequency = rknpu_dev->current_freq;

	/*
	 * Aggregate busy_time across all subcores.  The hrtimer handler
	 * snapshots total_busy_time every RKNPU_LOAD_INTERVAL (1 s).
	 */
	for (int i = 0; i < rknpu_dev->config->num_irqs; i++) {
		subcore_data = &rknpu_dev->subcore_datas[i];
		spin_lock_irqsave(&rknpu_dev->irq_lock, flags);
		busy += subcore_data->timer.total_busy_time;
		spin_unlock_irqrestore(&rknpu_dev->irq_lock, flags);
	}

	/* Express times in microseconds for the devfreq governor. */
	stat->busy_time = ktime_to_us(busy);
	stat->total_time = RKNPU_LOAD_INTERVAL / 1000; /* ns -> us */

	return 0;
}

static int npu_devfreq_get_cur_freq(struct device *dev, unsigned long *freq)
{
	struct rknpu_device *rknpu_dev = dev_get_drvdata(dev);

	*freq = rknpu_dev->current_freq;
	return 0;
}

static struct devfreq_dev_profile npu_devfreq_profile = {
	.polling_ms = 50,
	.target = npu_devfreq_target,
	.get_dev_status = npu_devfreq_get_dev_status,
	.get_cur_freq = npu_devfreq_get_cur_freq,
};

/* ------------------------------------------------------------------ */
/*  Public API consumed by rknpu_drv.c                                */
/* ------------------------------------------------------------------ */

void rknpu_devfreq_lock(struct rknpu_device *rknpu_dev)
{
	if (rknpu_dev->devfreq)
		mutex_lock(&rknpu_dev->devfreq_lock);
}
EXPORT_SYMBOL(rknpu_devfreq_lock);

void rknpu_devfreq_unlock(struct rknpu_device *rknpu_dev)
{
	if (rknpu_dev->devfreq)
		mutex_unlock(&rknpu_dev->devfreq_lock);
}
EXPORT_SYMBOL(rknpu_devfreq_unlock);

/*
 * Built-in fallback OPP table for RK3588, used only when the DT carries
 * no operating-points-v2 for the NPU (mainline rk3588 DTs don't today).
 * Voltages are deliberately rounded UP from Rockchip's BSP table
 * (300-700 MHz: 700-750 mV, 800: 750, 900: 800, 1000: 850 mV typ.) so a
 * worst-bin die still has margin; the regulator's own DT constraints
 * (vdd_npu_s0: 550-950 mV) still cap everything.
 */
static const struct dev_pm_opp_data rknpu_rk3588_fallback_opps[] = {
	{ .freq =  300000000, .u_volt = 800000 },
	{ .freq =  400000000, .u_volt = 800000 },
	{ .freq =  500000000, .u_volt = 825000 },
	{ .freq =  600000000, .u_volt = 850000 },
	{ .freq =  700000000, .u_volt = 875000 },
	{ .freq =  800000000, .u_volt = 900000 },
	{ .freq =  900000000, .u_volt = 925000 },
	{ .freq = 1000000000, .u_volt = 950000 },
};

int rknpu_devfreq_init(struct rknpu_device *rknpu_dev)
{
	struct device *dev = rknpu_dev->dev;
	struct devfreq_dev_profile *dp = &npu_devfreq_profile;
	struct dev_pm_opp *opp;
	struct regulator *reg;
	struct clk *clk;
	int ret;
	static const char * const reg_names_rknpu[] = { "rknpu", NULL };
	static const char * const reg_names_npu[] = { "npu", NULL };
	static const char * const clk_names_npu[] = { "clk_npu", NULL };
	static const char * const clk_names_scmi[] = { "scmi_clk", NULL };
	struct dev_pm_opp_config config = {
		.regulator_names = reg_names_rknpu,
		.clk_names = clk_names_npu,
	};

	/*
	 * Tell the OPP framework which regulator and clock to manage.
	 * Vendor DTs name the supply "rknpu-supply", mainline-style DTs
	 * name it "npu-supply" — probe for whichever this DT uses.
	 * Likewise the SCMI compute clock (the one whose rate actually
	 * controls the NPU frequency through the SCMI firmware) is
	 * "clk_npu" in vendor DTs, "scmi_clk" in some overlays.
	 */
	reg = regulator_get_optional(dev, "rknpu");
	if (reg == ERR_PTR(-ENODEV))
		config.regulator_names = reg_names_npu;
	else if (!IS_ERR(reg))
		regulator_put(reg);

	clk = clk_get(dev, "clk_npu");
	if (IS_ERR(clk))
		config.clk_names = clk_names_scmi;
	else
		clk_put(clk);

	ret = devm_pm_opp_set_config(dev, &config);
	if (ret) {
		LOG_DEV_ERROR(dev, "failed to set OPP config (reg %s, clk %s): %d\n",
			      config.regulator_names[0], config.clk_names[0],
			      ret);
		return ret;
	}

	ret = devm_pm_opp_of_add_table(dev);
	if (ret) {
		int i;

		if (!of_device_is_compatible(dev->of_node,
					     "rockchip,rk3588-rknpu")) {
			LOG_DEV_ERROR(dev, "failed to add OPP table: %d\n",
				      ret);
			return ret;
		}
		LOG_DEV_INFO(dev,
			     "no OPP table in DT (%d), using built-in rk3588 table\n",
			     ret);
		for (i = 0; i < ARRAY_SIZE(rknpu_rk3588_fallback_opps); i++) {
			struct dev_pm_opp_data data =
				rknpu_rk3588_fallback_opps[i];

			ret = dev_pm_opp_add_dynamic(dev, &data);
			if (ret)
				LOG_DEV_INFO(dev,
					     "skipping OPP %lu Hz: %d\n",
					     data.freq, ret);
		}
	}

	rknpu_dev->current_freq = clk_get_rate(rknpu_dev->clks[0].clk);

	opp = devfreq_recommended_opp(dev, &rknpu_dev->current_freq, 0);
	if (IS_ERR(opp)) {
		ret = PTR_ERR(opp);
		LOG_DEV_ERROR(dev, "failed to get recommended OPP: %d\n", ret);
		return ret;
	}
	dev_pm_opp_put(opp);

	dp->initial_freq = rknpu_dev->current_freq;

	ret = devfreq_add_governor(&devfreq_rknpu_ondemand);
	if (ret) {
		LOG_DEV_ERROR(dev, "failed to add rknpu_ondemand governor: %d\n",
			      ret);
		return ret;
	}

	rknpu_dev->devfreq = devm_devfreq_add_device(dev, dp,
						      "rknpu_ondemand",
						      (void *)rknpu_dev);
	if (IS_ERR(rknpu_dev->devfreq)) {
		LOG_DEV_ERROR(dev, "failed to add devfreq device\n");
		ret = PTR_ERR(rknpu_dev->devfreq);
		rknpu_dev->devfreq = NULL;
		goto err_remove_governor;
	}

	rknpu_dev->current_freq = clk_get_rate(rknpu_dev->clks[0].clk);
	rknpu_dev->ondemand_freq = rknpu_dev->current_freq;
	if (rknpu_dev->vdd)
		rknpu_dev->current_volt = regulator_get_voltage(rknpu_dev->vdd);

	rknpu_dev->devfreq->previous_freq = rknpu_dev->current_freq;
	if (rknpu_dev->devfreq->suspend_freq)
		rknpu_dev->devfreq->resume_freq = rknpu_dev->current_freq;
	rknpu_dev->devfreq->last_status.current_frequency =
		rknpu_dev->current_freq;
	rknpu_dev->devfreq->last_status.total_time = 1;
	rknpu_dev->devfreq->last_status.busy_time = 1;

	LOG_DEV_INFO(dev, "devfreq enabled, initial freq: %lu Hz, volt: %lu uV\n",
		     rknpu_dev->current_freq, rknpu_dev->current_volt);

	return 0;

err_remove_governor:
	devfreq_remove_governor(&devfreq_rknpu_ondemand);
	return ret;
}
EXPORT_SYMBOL(rknpu_devfreq_init);

void rknpu_devfreq_remove(struct rknpu_device *rknpu_dev)
{
	if (rknpu_dev->devfreq)
		devfreq_remove_governor(&devfreq_rknpu_ondemand);
	/* No-op unless init fell back to the built-in dynamic OPP table. */
	dev_pm_opp_remove_all_dynamic(rknpu_dev->dev);
}
EXPORT_SYMBOL(rknpu_devfreq_remove);

int rknpu_devfreq_runtime_suspend(struct device *dev)
{
	return 0;
}
EXPORT_SYMBOL(rknpu_devfreq_runtime_suspend);

int rknpu_devfreq_runtime_resume(struct device *dev)
{
	return 0;
}
EXPORT_SYMBOL(rknpu_devfreq_runtime_resume);

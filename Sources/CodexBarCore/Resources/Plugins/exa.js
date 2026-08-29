defineProvider({
  id: "exa",
  name: "Exa",
  endpoints: ["https://admin-api.exa.ai"],
  capabilities: ["http-status"],
  auth: { type: "x-api-key", secret: "EXA_SERVICE_API_KEY" },
  settings: [{ key: "EXA_SERVICE_API_KEY", title: "Service API key", type: "secure" }],
  async fetchUsage(ctx) {
    async function getJSON(url) {
      let response;
      try {
        response = await ctx.http.getJSON(url);
      } catch (error) {
        throw ctx.fail.networkFailure(`Exa request failed: ${(error && error.message) || error}`);
      }
      if (response.status === 401 || response.status === 403)
        throw ctx.fail.authenticationExpired("Exa rejected the service API key.");
      if (response.status === 429) throw ctx.fail.rateLimited("Exa usage request was rate limited.");
      if (response.status !== 200) throw ctx.fail.apiFailure(`Exa admin API returned HTTP ${response.status}.`);
      return response.json;
    }

    const list = await getJSON("https://admin-api.exa.ai/team-management/api-keys");
    const keys = Array.isArray(list) ? list : Array.isArray(list.api_keys) ? list.api_keys : list.data;
    if (!Array.isArray(keys)) throw ctx.fail.parseFailure("Exa API key list is not an array.");
    const reports = [];
    for (const key of keys) {
      if (!key || typeof key.id !== "string") continue;
      const usage = await getJSON(
        `https://admin-api.exa.ai/team-management/api-keys/${encodeURIComponent(key.id)}/usage`,
      );
      if (typeof usage.total_cost_usd !== "number" || !Number.isFinite(usage.total_cost_usd))
        throw ctx.fail.parseFailure(`Exa usage for ${key.name || key.id} has an invalid total.`);
      reports.push({ key, usage });
    }

    const total = reports.reduce((sum, report) => sum + report.usage.total_cost_usd, 0);
    const budgetCents = (key) =>
      typeof key.budgetCents === "number"
        ? key.budgetCents
        : typeof key.budget_cents === "number"
          ? key.budget_cents
          : null;
    const budget = reports.reduce((sum, report) => sum + (budgetCents(report.key) || 0) / 100, 0);
    const fmt = (value) => ctx.format.usd(value);
    const keyRows = reports.map((report) => ({
      label: report.key.name || report.usage.api_key_name || report.key.id,
      value: fmt(report.usage.total_cost_usd),
      secondaryValue: budgetCents(report.key) !== null ? `${fmt(budgetCents(report.key) / 100)} budget` : null,
    }));
    const breakdown = {};
    for (const report of reports) {
      for (const row of Array.isArray(report.usage.cost_breakdown) ? report.usage.cost_breakdown : []) {
        if (typeof row.price_name === "string" && typeof row.amount_usd === "number")
          breakdown[row.price_name] = (breakdown[row.price_name] || 0) + row.amount_usd;
      }
    }
    const breakdownRows = Object.keys(breakdown)
      .sort((a, b) => breakdown[b] - breakdown[a])
      .map((name) => ({ label: name, value: fmt(breakdown[name]) }));
    return {
      primary: budget > 0 ? { usedPercent: ctx.pct(total, budget) } : null,
      cost: { used: total, limit: budget, currency: "USD", period: "Last 30 days" },
      identity: { loginMethod: `${reports.length} API key${reports.length === 1 ? "" : "s"}` },
      dataConfidence: "exact",
      details: [
        { title: "Spend by API key", rows: keyRows },
        { title: "Spend by product", rows: breakdownRows },
      ],
    };
  },
});

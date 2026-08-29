defineProvider({
  id: "tavily",
  name: "Tavily",
  endpoints: ["https://api.tavily.com"],
  capabilities: ["http-status"],
  auth: { type: "bearer", secret: "TAVILY_API_KEY" },
  settings: [{ key: "TAVILY_API_KEY", title: "API key", type: "secure" }],
  async fetchUsage(ctx) {
    let response;
    try {
      response = await ctx.http.getJSON("https://api.tavily.com/usage");
    } catch (error) {
      throw ctx.fail.networkFailure(`Tavily usage request failed: ${(error && error.message) || error}`);
    }
    if (response.status === 401 || response.status === 403)
      throw ctx.fail.authenticationExpired("Tavily rejected the API key.");
    if (response.status === 429) throw ctx.fail.rateLimited("Tavily usage request was rate limited.");
    if (response.status !== 200) throw ctx.fail.apiFailure(`Tavily usage API returned HTTP ${response.status}.`);

    const payload = response.json;
    if (!payload || typeof payload !== "object" || !payload.key || !payload.account)
      throw ctx.fail.parseFailure("Tavily usage response is missing key or account data.");
    const number = (value, label) => {
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0)
        throw ctx.fail.parseFailure(`Tavily ${label} is invalid.`);
      return value;
    };
    const keyUsage = number(payload.key.usage, "key usage");
    const keyLimit = number(payload.key.limit, "key limit");
    const planUsage = number(payload.account.plan_usage, "plan usage");
    const planLimit = number(payload.account.plan_limit, "plan limit");
    const fmt = (value) => ctx.format.number(value, { maximumFractionDigits: 2 });
    const usageRows = (value) =>
      ["search", "extract", "crawl", "map", "research"]
        .filter((name) => typeof value[`${name}_usage`] === "number")
        .map((name) => ({ label: name[0].toUpperCase() + name.slice(1), value: fmt(value[`${name}_usage`]) }));
    const paygoUsage = typeof payload.account.paygo_usage === "number" ? payload.account.paygo_usage : 0;
    const paygoLimit = typeof payload.account.paygo_limit === "number" ? payload.account.paygo_limit : 0;
    return {
      primary: keyLimit > 0 ? { usedPercent: ctx.pct(keyUsage, keyLimit) } : null,
      secondary: planLimit > 0 ? { usedPercent: ctx.pct(planUsage, planLimit) } : null,
      identity: { loginMethod: String(payload.account.current_plan || "API") },
      dataConfidence: "exact",
      details: [
        {
          title: "Credits",
          rows: [
            { label: "API key", value: `${fmt(keyUsage)} used`, secondaryValue: `${fmt(keyLimit)} limit` },
            { label: "Plan", value: `${fmt(planUsage)} used`, secondaryValue: `${fmt(planLimit)} limit` },
            { label: "Pay as you go", value: `${fmt(paygoUsage)} used`, secondaryValue: `${fmt(paygoLimit)} limit` },
          ],
        },
        { title: "Account activity", rows: usageRows(payload.account) },
      ],
    };
  },
});

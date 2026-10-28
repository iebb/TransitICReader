const secretHeader = "X-CardBal-Proxy-Token";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "POST") {
      if (url.pathname !== "/api/v1/station-reports") {
        return Response.json({ error: "method_not_allowed" }, { status: 405 });
      }
      const key = request.headers.get("CF-Connecting-IP") ?? "unknown";
      const rate = await env.SUBMISSION_RATE_LIMITER.limit({ key });
      if (!rate.success) {
        return Response.json({ error: "rate_limited", message: "Please try again in a minute." }, {
          status: 429,
          headers: { "Retry-After": "60", "Cache-Control": "no-store" },
        });
      }
    } else if (request.method !== "GET" && request.method !== "HEAD") {
      return Response.json({ error: "method_not_allowed" }, { status: 405 });
    }

    const upstream = new URL(url.pathname + url.search, env.UPSTREAM_ORIGIN);
    const headers = new Headers(request.headers);
    headers.delete("Cookie");
    headers.delete("Authorization");
    headers.delete(secretHeader);
    headers.set(secretHeader, env.PROXY_TOKEN);
    return fetch(new Request(upstream, {
      method: request.method,
      headers,
      body: request.method === "POST" ? request.body : undefined,
      redirect: "manual",
    }));
  },
} satisfies ExportedHandler<EdgeEnv>;

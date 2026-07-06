import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Auto-memoizes components/hooks, cutting re-renders during the app's
  // frequent live-data refreshes without hand-written useMemo/useCallback.
  reactCompiler: true,
  poweredByHeader: false,
};

export default nextConfig;

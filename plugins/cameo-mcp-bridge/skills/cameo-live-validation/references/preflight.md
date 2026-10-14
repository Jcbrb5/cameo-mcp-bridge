# Preflight

- Probe the bridge before assuming it is live:
  - `cameo_probe_bridge`
  - `cameo_status`
  - `cameo_get_capabilities`
  - `cameo_get_project`
- A healthy bridge is not enough; `cameo_get_project` must show an open project or model mutation will fail.
- When Java bridge code changes, rebuild, redeploy, and fully restart Cameo before trusting live results.
- Gradle/plugin deploy work needs a JDK 21 (CATIA Magic 2026x).
- This repo lives on a UNC path; Git or shell behavior may need UNC-safe handling.

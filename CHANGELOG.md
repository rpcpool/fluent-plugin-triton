# [0.1.2]

- This release introduces a critical fix to enhance the stability of fluent-plugin-triton when connecting to Nomad.

Key Changes:

Improved Connection Resilience: The Nomad client within the plugin now handles connection failures (e.g., Connection refused) more gracefully. Instead of raising an exception that could halt Fluentd startup or fail configuration validation, it will now:

Log a warning message for connectivity issues.

Return empty data (e.g., an empty array) to calling methods.

Smoother Deployments: Prevents Ansible validate steps from failing when Nomad is temporarily unavailable during Fluentd configuration application.

Enhanced Stability: Ensures Fluentd continues to run even if Nomad becomes intermittently unreachable.

# [0.1.1]

- Allow failed nomad connection failure during nomad API lookup, this is to prevent fluentd to crash when booting


# [0.1.0]

Initial release

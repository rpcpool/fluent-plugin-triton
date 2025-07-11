
# [0.1.3]

- Catch systemcall error during http request.

# [0.1.2]

- relaced error-level log during configure for warn-level, to remove confusion when doing ops.
- Fix missing call to `try_update_alloc_cache` in the nomad plugin.
- Fix `NomadClientRequestError` constructor
- Added timeout support for nomad request
- Added unit tests for 4xx support + timeout support of nomad client

# [0.1.1]

- Allow failed nomad connection failure during nomad API lookup, this is to prevent fluentd to crash when booting


# [0.1.0]

Initial release
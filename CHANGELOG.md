
# [0.1.2]

- relaced error-level log during configure for warn-level, to remove confusion when doing ops.
- Fix missing call to `try_update_alloc_cache` in the nomad plugin.


# [0.1.1]

- Allow failed nomad connection failure during nomad API lookup, this is to prevent fluentd to crash when booting


# [0.1.0]

Initial release
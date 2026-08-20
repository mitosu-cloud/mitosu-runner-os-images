# Common image content

This directory owns shared resolver content and marker generation. The
distribution Containerfiles consume these files rather than duplicate the
guest contract. Large build state and container storage are always rooted under
`MITOSU_BUILD_ROOT`, which defaults to `/tmp/mitosu-runner-os-images`.

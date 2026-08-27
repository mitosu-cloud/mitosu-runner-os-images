# AlmaLinux image family

The common stage consumes the digest-pinned AlmaLinux 10.2 base, exact RPM
NEVRAs, and checksum-locked AlmaLinux/EPEL metadata from
`locks/os/almalinux-10.json`. Profile stages will extend this Containerfile in
Phase 3.

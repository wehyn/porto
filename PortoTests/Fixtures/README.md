# Parser fixtures

The parser tests construct NUL-delimited `lsof -F0` byte fixtures in Swift so
the structural separators remain explicit and invalid UTF-8 can be tested
without relying on a text-file encoding. The fixtures cover IPv4/IPv6 TCP and
UDP listeners, remote endpoints, repeated fields, duplicate states, malformed
records, and unknown fields.

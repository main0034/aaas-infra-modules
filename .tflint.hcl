# tflint configuration.
#
# Deliberately minimal. An earlier version set a top-level `plugin_dir`
# attribute, which is not valid at that level - tflint rejects the whole
# config and exits 1 before linting anything, which looks identical to a
# lint failure. Plugin location is handled by `tflint --init` and the
# TFLINT_PLUGIN_DIR environment variable if it is ever needed.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

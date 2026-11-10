# tflint configuration (ADR-0023). The terraform ruleset is bundled with tflint (no download).
# Provider rulesets are added when the first OpenTofu code arrives (P1).
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

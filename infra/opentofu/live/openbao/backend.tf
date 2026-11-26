# State in the L0 bucket of ADR-0031 under its own key (ADR-0046). The bucket name is private:
# it comes from a partial configuration outside the repository,
#   tofu init -backend-config="$HOME/akasha-private/openbao.s3.tfbackend"
# (bucket, key = "openbao/terraform.tfstate", region, use_lockfile = true), and the
# credentials from AWS_PROFILE=akasha-l0 (`aws login`).
terraform {
  backend "s3" {}
}

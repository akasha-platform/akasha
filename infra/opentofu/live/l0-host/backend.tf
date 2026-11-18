# State in the dedicated AWS S3 bucket of ADR-0031 (eu-west-3). The bucket name is private:
# it comes from a partial configuration outside the repository,
#   tofu init -backend-config="$HOME/akasha-private/l0.s3.tfbackend"
# (bucket, key = "l0/terraform.tfstate", region, use_lockfile = true), and the credentials
# from AWS_PROFILE=akasha-l0 (`aws login`). See docs/runbooks/opentofu-l0.md.
terraform {
  backend "s3" {}
}

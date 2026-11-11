# Solo para test/run.sh: lo que necesita el harness para lanzar las VMs.
output "test_assets_bucket" {
  value = aws_s3_bucket.assets.id
}

output "test_user_data_main" {
  value = local.user_data["main"]
}

output "test_user_data_worker" {
  value = local.user_data["worker"]
}

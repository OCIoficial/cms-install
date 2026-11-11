# Solo para test/run.sh: el proveedor de AWS usa moto (S3 local) en vez de AWS.
provider "aws" {
  region                      = "us-east-2"
  profile                     = null
  access_key                  = "test"
  secret_key                  = "test"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  endpoints {
    s3 = "http://10.20.0.1:5000"
  }
}

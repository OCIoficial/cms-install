# Roles de las instancias: acceso por SSM Session Manager y lectura del bucket
# de assets. Los workers no pueden leer secrets/ ni la config del ranking.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "main" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.assets.arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]
  }
}

data "aws_iam_policy_document" "worker" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.assets.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["scripts/*", "scripts"]
    }
  }
  statement {
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.assets.arn}/scripts/*",
      "${aws_s3_bucket.assets.arn}/config/cms.toml",
    ]
  }
}

resource "aws_iam_role" "host" {
  for_each           = toset(["main", "worker"])
  name_prefix        = "cms-${each.key}-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = aws_iam_role.host
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "main" {
  role   = aws_iam_role.host["main"].name
  policy = data.aws_iam_policy_document.main.json
}

resource "aws_iam_role_policy" "worker" {
  role   = aws_iam_role.host["worker"].name
  policy = data.aws_iam_policy_document.worker.json
}

resource "aws_iam_instance_profile" "host" {
  for_each    = aws_iam_role.host
  name_prefix = "cms-${each.key}-"
  role        = each.value.name
}

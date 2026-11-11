output "urls" {
  value = { for k, d in local.domains : k => "https://${d}" }
}

output "main_public_ip" {
  value = aws_eip.main.public_ip
}

output "ssh_main" {
  value = "ssh ubuntu@${aws_eip.main.public_ip}"
}

output "ssm_main" {
  value = "aws ssm start-session --target ${aws_instance.main.id}"
}

output "workers" {
  value = {
    for i, w in aws_instance.worker : "worker-${i + 1}" => {
      id         = w.id
      private_ip = w.private_ip
      state      = aws_ec2_instance_state.worker[i].state
    }
  }
}

output "cms_workers" {
  description = "Workers de CMS en la configuración actual"
  value       = [for w in local.cms_workers : "${w[0]}:${w[1]}"]
}

output "admin_username" {
  value = var.admin_username
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

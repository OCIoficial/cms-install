output "urls" {
  value = { for k, d in local.domains : k => "https://${d}" }
}

# IP pública de la principal, para scripts (cms-task-push)
output "main_ip" {
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
      ssh        = "ssh -J ubuntu@${aws_eip.main.public_ip} ubuntu@${w.private_ip}"
    }
  }
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}
